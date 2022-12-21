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
## * `{missing-storage-slots}`: list implemented as pair of queues
##   `env.fetchStorageFull` and `env.fetchStoragePart`
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
  ../../../sync_desc,
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_storage_ranges],
  ../db/[hexary_error, snapdb_storage_slots]

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
# Private helpers
# ------------------------------------------------------------------------------

proc getNextSlotItemsFull(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): seq[AccountSlotsHeader] =
  ## Get list of full work item from the batch queue.
    ##
  ## If there is an indication that the storage trie may have some data
  ## already it is ignored here and marked `inherit` so that it will be
  ## picked up by the healing process.
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var
    nInherit = 0
  for kvp in env.fetchStorageFull.nextPairs:
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
    env.fetchStorageFull.del(kvp.key) # ok to delete this item from batch queue

    # Maximal number of items to fetch
    if fetchRequestStorageSlotsMax <= result.len:
      break

  when extraTraceMessages:
    trace logTxt "fetch full", peer, nSlotLists=env.nSlotLists,
       nStorageQuFull=env.fetchStorageFull.len, nToProcess=result.len, nInherit


proc getNextSlotItemPartial(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): seq[AccountSlotsHeader] =
  ## Get work item from the batch queue.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  for kvp in env.fetchStoragePart.nextPairs:
    if not kvp.data.slots.isNil:
      # Extract range and return single item request queue
      let rc = kvp.data.slots.unprocessed.fetch(maxLen = high(UInt256))
      if rc.isOk:

        # Delete from batch queue if the range set becomes empty
        if kvp.data.slots.unprocessed.isEmpty:
          env.fetchStoragePart.del(kvp.key)

        when extraTraceMessages:
          trace logTxt "fetch partial", peer,
            nSlotLists=env.nSlotLists,
            nStorageQuPart=env.fetchStoragePart.len,
            subRange=rc.value, account=kvp.data.accKey

        return @[AccountSlotsHeader(
          accKey:      kvp.data.accKey,
          storageRoot: kvp.key,
          subRange:    some rc.value)]

    # Oops, empty range set? Remove range and move item to the full requests
    kvp.data.slots = nil
    env.fetchStorageFull.merge kvp


proc backToSlotItemsQueue(env: SnapPivotRef; req: seq[AccountSlotsHeader]) =
  if 0 < req.len:
    if req[^1].subRange.isSome:
      env.fetchStoragePart.merge req[^1]
      env.fetchStorageFull.merge req[0 ..< req.len-1]
    else:
      env.fetchStorageFull.merge req

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc storeStoragesSingleBatch(
    buddy: SnapBuddyRef;
    req: seq[AccountSlotsHeader];
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch account storage slots and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req, pivot)
    if rc.isErr:
      env.backToSlotItemsQueue req

      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
        trace logTxt "fetch error => stop", peer, pivot,
          nSlotLists=env.nSlotLists, nReq=req.len, nStorageQueue, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  var gotSlotLists = stoRange.data.storages.len

  #when extraTraceMessages:
  #  let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
  #  trace logTxt "fetched", peer, pivot, nSlotLists=env.nSlotLists,
  #    nSlotLists=gotSlotLists, nReq=req.len,
  #    nStorageQueue, nLeftOvers=stoRange.leftOver.len

  if 0 < gotSlotLists:
    # Verify/process storages data and save it to disk
    let report = ctx.data.snapDb.importStorageSlots(
      peer, stoRange.data, noBaseBoundCheck = true)

    if 0 < report.len:
      let topStoRange = stoRange.data.storages.len - 1

      if report[^1].slot.isNone:
        # Failed to store on database, not much that can be done here
        env.backToSlotItemsQueue req
        gotSlotLists.dec(report.len - 1) # for logging only

        let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
        error logTxt "import failed", peer, pivot,
          nSlotLists=env.nSlotLists, nSlotLists=gotSlotLists, nReq=req.len,
          nStorageQueue, error=report[^1].error
        return

      # Push back error entries to be processed later
      for w in report:
        # All except the last item always index to a node argument. The last
        # item has been checked for, already.
        let
          inx = w.slot.get
          acc = stoRange.data.storages[inx].account

        if w.error == RootNodeMismatch:
          # Some pathological case, needs further investigation. For the
          # moment, provide partial fetches.
          const
            halfTag = (high(UInt256) div 2).NodeTag
            halfTag1 = halfTag + 1.u256
          env.fetchStoragePart.merge [
            AccountSlotsHeader(
              accKey:      acc.accKey,
              storageRoot: acc.storageRoot,
              subRange:    some NodeTagRange.new(low(NodeTag), halfTag)),
            AccountSlotsHeader(
              accKey:      acc.accKey,
              storageRoot: acc.storageRoot,
              subRange:    some NodeTagRange.new(halfTag1, high(NodeTag)))]

        elif w.error == RightBoundaryProofFailed and
             acc.subRange.isSome and 1 < acc.subRange.unsafeGet.len:
          # Some pathological case, needs further investigation. For the
          # moment, provide a partial fetches.
          let
            iv = acc.subRange.unsafeGet
            halfTag = iv.minPt + (iv.len div 2)
            halfTag1 = halfTag + 1.u256
          env.fetchStoragePart.merge [
            AccountSlotsHeader(
              accKey:      acc.accKey,
              storageRoot: acc.storageRoot,
              subRange:    some NodeTagRange.new(iv.minPt, halfTag)),
            AccountSlotsHeader(
              accKey:      acc.accKey,
              storageRoot: acc.storageRoot,
              subRange:    some NodeTagRange.new(halfTag1, iv.maxPt))]

        else:
          # Reset any partial result (which would be the last entry) to
          # requesting the full interval. So all the storage slots are
          # re-fetched completely for this account.
          env.fetchStorageFull.merge AccountSlotsHeader(
            accKey:      acc.accKey,
            storageRoot: acc.storageRoot)

          # Last entry might be partial (if any)
          #
          # Forget about partial result processing if the last partial entry
          # was reported because
          # * either there was an error processing it
          # * or there were some gaps reprored as dangling links
          stoRange.data.proof = @[]

        # Update local statistics counter for `nSlotLists` counter update
        gotSlotLists.dec

        let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
        error logTxt "processing error", peer, pivot, nSlotLists=env.nSlotLists,
          nSlotLists=gotSlotLists, nReqInx=inx, nReq=req.len,
          nStorageQueue, nDangling=w.dangling.len, error=w.error

    # Update statistics
    if gotSlotLists == 1 and
       req[0].subRange.isSome and
       env.fetchStoragePart.hasKey req[0].storageRoot:
      # Successful partial request, but not completely done with yet.
      gotSlotLists = 0

    env.nSlotLists.inc(gotSlotLists)

  # Return unprocessed left overs to batch queue
  env.backToSlotItemsQueue stoRange.leftOver

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchStorageSlots*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch some account storage slots and store them in the database. If left
  ## anlone (e.t. no patallel activated processes) this function tries to fetch
  ## each work item on the queue at least once.For partial partial slot range
  ## items this means in case of success that the outstanding range has become
  ## at least smaller.
  let
    peer = buddy.peer
    fullRangeLen = env.fetchStorageFull.len
    partRangeLen = env.fetchStoragePart.len

  # Fetch storage data and save it on disk. Storage requests are managed by
  # request queues for handling full/partial replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.
  if 0 < fullRangeLen or 0 < partRangeLen:

    when extraTraceMessages:
      trace logTxt "start", peer, nSlotLists=env.nSlotLists,
        nStorageQueue=(fullRangeLen+partRangeLen)

    # Processing the full range will implicitely handle inheritable storage
    # slots first with each batch item (see `getNextSlotItemsFull()`.)
    #
    # Run this batch even if `archived` flag is set in order to shrink the
    # batch queue.
    var fullRangeItemsleft = 1+(fullRangeLen-1) div fetchRequestStorageSlotsMax
    while 0 < fullRangeItemsleft and
          buddy.ctrl.running:
      # Pull out the next request list from the queue
      let req = buddy.getNextSlotItemsFull(env)
      if req.len == 0:
        break

      fullRangeItemsleft.dec
      await buddy.storeStoragesSingleBatch(req, env)

    var partialRangeItemsLeft = env.fetchStoragePart.len
    while 0 < partialRangeItemsLeft and
          buddy.ctrl.running:
      # Pull out the next request list from the queue
      let req = buddy.getNextSlotItemPartial(env)
      if req.len == 0:
        break
      partialRangeItemsLeft.dec
      await buddy.storeStoragesSingleBatch(req, env)

    when extraTraceMessages:
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "done", peer, nSlotLists=env.nSlotLists, nStorageQueue,
        fullRangeItemsleft, partialRangeItemsLeft, runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
