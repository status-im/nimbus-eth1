# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch accounts stapshot
## =======================
##
## Flow chart for storage slots download
## -------------------------------------
## ::
##   {missing-storage-slots} <-----------------+
##     |                                       |
##     v                                       |
##   <fetch-storage-slots-from-network>        |
##     |                                       |
##     v                                       |
##   {storage-slots}                           |
##     |                                       |
##     v                                       |
##   <merge-to-persistent-database>            |
##     |              |                        |
##     v              v                        |
##   {completed}    {partial}                  |
##     |              |                        |
##     |              +------------------------+
##     v
##   <done-for-this-account>
##
## Legend:
## * `<..>`: some action, process, etc.
## * `{missing-storage-slots}`: list implemented as `env.fetchStorage`
## * `(storage-slots}`: list is optimised out
## * `{completed}`: list is optimised out
## * `{partial}`: list is optimised out
##

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_storage_ranges],
  ./db/snapdb_storage_slots

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getNextSlotItems(buddy: SnapBuddyRef): seq[AccountSlotsHeader] =
  ## Get list of work item from the batch queue.
  ##
  ## * If the storage slots requested come with an explicit sub-range of slots
  ##   (i.e. not an implied complete list), then the result has only on work
  ##   item. An explicit list of slots is only calculated if there was a queue
  ##   item with a partially completed slots download.
  ##
  ## * Otherwise, a list of at most `maxStoragesFetch` work items is returned.
  ##   These work items are checked for that there was no trace of a previously
  ##   installed (probably partial) storage trie on the database (e.g. inherited
  ##   from an earlier state root pivot.)
  ##
  ##   If there is an indication that the storage trie may have some data
  ##   already it is ignored here and marked `inherit` so that it will be
  ##   picked up by the healing process.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv

    (reqKey, reqData) = block:
      let rc = env.fetchStorage.first # peek
      if rc.isErr:
        return
      (rc.value.key, rc.value.data)

  # Assemble first request which might come with a sub-range.
  while not reqData.slots.isNil:
    # Extract first interval and return single item request queue
    for ivSet in reqData.slots.unprocessed:
      let rc = ivSet.ge()
      if rc.isOk:

        # Extraxt this interval from the range set
        discard ivSet.reduce rc.value

        # Delete from batch queue if the range set becomes empty
        if reqData.slots.unprocessed.isEmpty:
          env.fetchStorage.del(reqKey)

        when extraTraceMessages:
          trace "Prepare fetching partial storage slots", peer,
            nStorageQueue=env.fetchStorage.len, subRange=rc.value,
            account=reqData.accHash.to(NodeTag)

        return @[AccountSlotsHeader(
          accHash:     reqData.accHash,
          storageRoot: reqKey.to(Hash256),
          subRange:    some rc.value)]

    # Oops, empty range set? Remove range and move item to the right end
    reqData.slots = nil
    discard env.fetchStorage.lruFetch(reqKey)

  # So there are no partial ranges (aka `slots`) anymore. Assemble maximal
  # request queue.
  for kvp in env.fetchStorage.nextPairs:
    let it = AccountSlotsHeader(
      accHash:     kvp.data.accHash,
      storageRoot: kvp.key.to(Hash256))

    # Verify whether a storage sub-trie exists, already
    if kvp.data.inherit or
       ctx.data.snapDb.haveStorageSlotsData(peer, it.accHash, it.storageRoot):
      kvp.data.inherit = true
      when extraTraceMessages:
        trace "Inheriting storage slots", peer,
          nStorageQueue=env.fetchStorage.len, account=it.accHash.to(NodeTag)
      continue

    result.add it
    env.fetchStorage.del(kvp.key) # ok to delete this item from batch queue

    # Maximal number of items to fetch
    if maxStoragesFetch <= result.len:
      break

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc storeStorages*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch account storage slots and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Fetch storage data and save it on disk. Storage requests are managed by
  # a request queue for handling partioal replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.

  # Pull out the next request list from the queue
  let req = buddy.getNextSlotItems()
  if req.len == 0:
     return # currently nothing to do

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req)
    if rc.isErr:
      env.fetchStorage.merge req

      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        discard
        trace "Error fetching storage slots => stop", peer,
          nReq=req.len, nStorageQueue=env.fetchStorage.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts
  buddy.data.errors.nTimeouts = 0

  var gotStorage = stoRange.data.storages.len

  when extraTraceMessages:
    trace "Fetched storage slots", peer, gotStorage,
      nReq=req.len, nStorageQueue=env.fetchStorage.len

  if 0 < gotStorage:
    # Verify/process storages data and save it to disk
    let report = ctx.data.snapDb.importStorageSlots(peer, stoRange.data)
    if 0 < report.len:

      # Update local statistics counter
      gotStorage.dec(report.len)

      if report[^1].slot.isNone:
        # Failed to store on database, not much that can be done here
        env.fetchStorage.merge req

        gotStorage.inc
        error "Error writing storage slots to database", peer, gotStorage,
          nReq=req.len, nStorageQueue=env.fetchStorage.len,
          error=report[^1].error
        return

      # Push back error entries to be processed later
      for w in report:
        # All except the last item always index to a node argument. The last
        # item has been checked for, already.
        let inx = w.slot.get

        # if w.error in {RootNodeMismatch, RightBoundaryProofFailed}:
        #   ???

        # Reset any partial requests to requesting the full interval. So
        # all the storage slots are re-fetched completely for this account.
        env.fetchStorage.merge AccountSlotsHeader(
          accHash:     stoRange.data.storages[inx].account.accHash,
          storageRoot: stoRange.data.storages[inx].account.storageRoot)

        trace "Error processing storage slots", peer, gotStorage,
          nReqInx=inx, nReq=req.len, nStorageQueue=env.fetchStorage.len,
          error=report[inx].error

    # Update statistics
    env.nStorage.inc(gotStorage)

  when extraTraceMessages:
    trace "Done fetching storage slots", peer, gotStorage,
      nStorageQueue=env.fetchStorage.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
