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
## Worker items state diagram:
## ::
##   unprocessed slot requests | peer workers + storages database update
##   ===================================================================
##
##        +-----------------------------------------------+
##        |                                               |
##        v                                               |
##   <unprocessed> ------------+-------> <worker-0> ------+
##                             |                          |
##                             +-------> <worker-1> ------+
##                             |                          |
##                             +-------> <worker-2> ------+
##                             :                          :
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
  ./db/[hexary_error, snapdb_storage_slots]

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getNextSlotItems(buddy: SnapBuddyRef): seq[AccountSlotsHeader] =
  let
    env = buddy.data.pivotEnv
    (reqKey, reqData) = block:
      let rc = env.fetchStorage.shift
      if rc.isErr:
        return
      (rc.value.key, rc.value.data)

  # Assemble first request
  result.add AccountSlotsHeader(
    accHash:     reqData.accHash,
    storageRoot: Hash256(data: reqKey))

  # Check whether it comes with a sub-range
  if not reqData.slots.isNil:
    # Extract some interval and return single item request queue
    for ivSet in reqData.slots.unprocessed:
      let rc = ivSet.ge()
      if rc.isOk:

        # Extraxt interval => done
        result[0].subRange = some rc.value
        discard ivSet.reduce rc.value

        # Puch back on batch queue unless it becomes empty
        if not reqData.slots.unprocessed.isEmpty:
          discard env.fetchStorage.unshift(reqKey, reqData)
        return

  # Append more full requests to returned list
  while result.len < maxStoragesFetch:
    let rc = env.fetchStorage.shift
    if rc.isErr:
      return
    result.add AccountSlotsHeader(
      accHash:     rc.value.data.accHash,
      storageRoot: Hash256(data: rc.value.key))

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

  when extraTraceMessages:
    trace "Start fetching storage slots", peer,
      nSlots=env.fetchStorage.len,
      nReq=req.len

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req)
    if rc.isErr:
      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        trace "Error fetching storage slots => stop", peer,
          nSlots=env.fetchStorage.len,
          nReq=req.len,
          error
        discard
      env.fetchStorage.merge req
      return
    rc.value

  # Reset error counts for detecting repeated timeouts
  buddy.data.errors.nTimeouts = 0

  if 0 < stoRange.data.storages.len:
    # Verify/process storages data and save it to disk
    let report = ctx.data.snapDb.importStorages(peer, stoRange.data)
    if 0 < report.len:

      if report[^1].slot.isNone:
        # Failed to store on database, not much that can be done here
        trace "Error writing storage slots to database", peer,
          nSlots=env.fetchStorage.len,
          nReq=req.len,
          error=report[^1].error
        env.fetchStorage.merge req
        return

      # Push back error entries to be processed later
      for w in report:
        if w.slot.isSome:
          let n = w.slot.unsafeGet
          # if w.error in {RootNodeMismatch, RightBoundaryProofFailed}:
          #   ???
          trace "Error processing storage slots", peer,
            nSlots=env.fetchStorage.len,
            nReq=req.len,
            nReqInx=n,
            error=report[n].error
          # Reset any partial requests to requesting the full interval. So
          # all the storage slots are re-fetched completely for this account.
          env.fetchStorage.merge AccountSlotsHeader(
            accHash:     stoRange.data.storages[n].account.accHash,
            storageRoot: stoRange.data.storages[n].account.storageRoot)

  when extraTraceMessages:
    trace "Done fetching storage slots", peer,
      nSlots=env.fetchStorage.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
