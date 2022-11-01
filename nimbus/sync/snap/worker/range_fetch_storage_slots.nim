# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch storage slots
## ===================
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
## Discussion
## ----------
## Handling storage slots can be seen as an generalisation of handling account
## ranges (see `range_fetch_accounts` module.) Contrary to the situation with
## accounts, storage slots are typically downloaded in the size of a full list
## that can be expanded to a full hexary trie for the given storage root.
##
## Only in rare cases a storage slots list is incomplete, a partial hexary
## trie. In that case, the list of storage slots is processed as described
## for accounts (see `range_fetch_accounts` module.)
##

import
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../sync_desc,
  ".."/[constants, range_desc, worker_desc],
  ./com/[com_error, get_storage_ranges],
  ./db/snapdb_storage_slots

{.push raises: [Defect].}

logScope:
  topics = "snap-range"

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage slots range " & info

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getNextSlotItems(
    buddy: SnapBuddyRef;
    noSubRange = false;
      ): seq[AccountSlotsHeader] =
  ## Get list of work item from the batch queue.
  ##
  ## * If the storage slots requested come with an explicit sub-range of slots
  ##   (i.e. not an implied complete list), then the result has only on work
  ##   item. An explicit list of slots is only calculated if there was a queue
  ##   item with a partially completed slots download.
  ##
  ## * Otherwise, a list of at most `snapStoragesSlotsFetchMax` work items is
  ##   returned. These work items were checked for that there was no trace of a
  ##   previously installed (probably partial) storage trie on the database
  ##   (e.g. inherited from an earlier state root pivot.)
  ##
  ##   If there is an indication that the storage trie may have some data
  ##   already it is ignored here and marked `inherit` so that it will be
  ##   picked up by the healing process.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv

  # Assemble first request which might come with a sub-range.
  if not noSubRange:
    let (reqKey, reqData) = block:
      let rc = env.fetchStorage.first # peek
      if rc.isErr:
        return
      (rc.value.key, rc.value.data)
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
            trace logTxt "prepare fetch partial", peer,
              nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len,
              nToProcess=1, subRange=rc.value, account=reqData.accKey

          return @[AccountSlotsHeader(
            accKey:      reqData.accKey,
            storageRoot: reqKey,
            subRange:    some rc.value)]

      # Oops, empty range set? Remove range and move item to the right end
      reqData.slots = nil
      discard env.fetchStorage.lruFetch(reqKey)

  # Done with partial slot ranges. Assemble maximal request queue.
  var nInherit = 0
  for kvp in env.fetchStorage.prevPairs:
    if not kvp.data.slots.isNil:
      # May happen when `noSubRange` is `true`. As the queue is read from the
      # right end and all the partial slot ranges are on the left there will
      # be no more non-partial slot ranges on the queue. So this loop is done.
      break

    let it = AccountSlotsHeader(
      accKey:      kvp.data.accKey,
      storageRoot: kvp.key)

    # Verify whether a storage sub-trie exists, already
    if kvp.data.inherit or
       ctx.data.snapDb.haveStorageSlotsData(peer, it.accKey, it.storageRoot):
      kvp.data.inherit = true
      nInherit.inc # update for logging
      continue

    result.add it
    env.fetchStorage.del(kvp.key) # ok to delete this item from batch queue

    # Maximal number of items to fetch
    if snapStoragesSlotsFetchMax <= result.len:
      break

  when extraTraceMessages:
    trace logTxt "fetch", peer, nSlotLists=env.nSlotLists,
      nStorageQueue=env.fetchStorage.len, nToProcess=result.len, nInherit


proc storeStoragesSingleBatch(
    buddy: SnapBuddyRef;
    noSubRange = false;
      ) {.async.} =
  ## Fetch account storage slots and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Fetch storage data and save it on disk. Storage requests are managed by
  # a request queue for handling partioal replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.

  # Pull out the next request list from the queue
  let req = buddy.getNextSlotItems()
  if req.len == 0:
     return # currently nothing to do

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req, pivot)
    if rc.isErr:
      env.fetchStorage.merge req

      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        discard
        trace logTxt "fetch error => stop", peer, pivot,
          nSlotLists=env.nSlotLists, nReq=req.len,
          nStorageQueue=env.fetchStorage.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  var gotSlotLists = stoRange.data.storages.len

  #when extraTraceMessages:
  #  trace logTxt "fetched", peer, pivot,
  #    nSlotLists=env.nSlotLists, nSlotLists=gotSlotLists, nReq=req.len,
  #    nStorageQueue=env.fetchStorage.len, nLeftOvers=stoRange.leftOver.len

  if 0 < gotSlotLists:
    # Verify/process storages data and save it to disk
    let report = ctx.data.snapDb.importStorageSlots(peer, stoRange.data)

    if 0 < report.len:
      let topStoRange = stoRange.data.storages.len - 1

      if report[^1].slot.isNone:
        # Failed to store on database, not much that can be done here
        env.fetchStorage.merge req
        gotSlotLists.dec(report.len - 1) # for logging only

        error logTxt "import failed", peer, pivot,
          nSlotLists=env.nSlotLists, nSlotLists=gotSlotLists, nReq=req.len,
          nStorageQueue=env.fetchStorage.len, error=report[^1].error
        return

      # Push back error entries to be processed later
      for w in report:
        # All except the last item always index to a node argument. The last
        # item has been checked for, already.
        let inx = w.slot.get

        # if w.error in {RootNodeMismatch, RightBoundaryProofFailed}:
        #   ???

        # Reset any partial result (which would be the last entry) to
        # requesting the full interval. So all the storage slots are
        # re-fetched completely for this account.
        env.fetchStorage.merge AccountSlotsHeader(
          accKey:      stoRange.data.storages[inx].account.accKey,
          storageRoot: stoRange.data.storages[inx].account.storageRoot)

        # Last entry might be partial
        if inx == topStoRange:
          # No partial result processing anymore to consider
          stoRange.data.proof = @[]

        # Update local statistics counter for `nSlotLists` counter update
        gotSlotLists.dec

        trace logTxt "processing error", peer, pivot, nSlotLists=env.nSlotLists,
          nSlotLists=gotSlotLists, nReqInx=inx, nReq=req.len,
          nStorageQueue=env.fetchStorage.len, error=report[inx].error

    # Update statistics
    if gotSlotLists == 1 and
       req[0].subRange.isSome and
       env.fetchStorage.hasKey req[0].storageRoot:
      # Successful partial request, but not completely done with yet.
      gotSlotLists = 0

    env.nSlotLists.inc(gotSlotLists)

  # Return unprocessed left overs to batch queue
  env.fetchStorage.merge stoRange.leftOver

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchStorageSlots*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch some account storage slots and store them in the database. If left
  ## anlone (e.t. no patallel activated processes) this function tries to fetch
  ## each work item on the queue at least once.For partial partial slot range
  ## items this means in case of success that the outstanding range has become
  ## at least smaller.
  let
    env = buddy.data.pivotEnv
    peer = buddy.peer

  if 0 < env.fetchStorage.len:
    # Run at most the minimum number of times to get the batch queue cleaned up.
    var
      fullRangeLoopCount =
        1 + (env.fetchStorage.len - 1) div snapStoragesSlotsFetchMax
      subRangeLoopCount = 0

    # Add additional counts for partial slot range items
    for reqData in env.fetchStorage.nextValues:
      if reqData.slots.isNil:
        break
      subRangeLoopCount.inc

    when extraTraceMessages:
      trace logTxt "start", peer, nSlotLists=env.nSlotLists,
        nStorageQueue=env.fetchStorage.len, fullRangeLoopCount,
        subRangeLoopCount

    # Processing the full range will implicitely handle inheritable storage
    # slots first wich each batch item (see `getNextSlotItems()`.)
    while 0 < fullRangeLoopCount and
          0 < env.fetchStorage.len and
          not buddy.ctrl.stopped:
      fullRangeLoopCount.dec
      await buddy.storeStoragesSingleBatch(noSubRange = true)

    while 0 < subRangeLoopCount and
          0 < env.fetchStorage.len and
          not buddy.ctrl.stopped:
      subRangeLoopCount.dec
      await buddy.storeStoragesSingleBatch(noSubRange = false)

    when extraTraceMessages:
      trace logTxt "done", peer, nSlotLists=env.nSlotLists,
        nStorageQueue=env.fetchStorage.len, fullRangeLoopCount,
        subRangeLoopCount

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
