# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  ../../../sync_desc,
  "../.."/[constants, range_desc, worker_desc],
  ../db/[hexary_inspect, snapdb_storage_slots]

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getOrMakePartial(
    env: SnapPivotRef;
    stoRoot: Hash256;
    accKey: NodeKey;
      ): (SnapSlotsQueueItemRef, bool) =
  ## Create record on `fetchStoragePart` or return existing one
  let rc = env.fetchStoragePart.lruFetch stoRoot
  if rc.isOk:
    result = (rc.value, true)                               # Value exists
  else:
    result = (SnapSlotsQueueItemRef(accKey: accKey), false) # New value
    env.parkedStorage.excl accKey                           # Un-park
    discard env.fetchStoragePart.append(stoRoot, result[0])

  if result[0].slots.isNil:
    result[0].slots = SnapRangeBatchRef(processed: NodeTagRangeSet.init())
    result[0].slots.unprocessed.init()

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc storageQueueTotal*(env: SnapPivotRef): int =
  ## Total number of entries on the storage queues
  env.fetchStorageFull.len + env.fetchStoragePart.len + env.parkedStorage.len

# ------------------------------------------------------------------------------
# Public functions, append queue items
# ------------------------------------------------------------------------------

proc storageQueueAppendFull*(
    env: SnapPivotRef;
    stoRoot: Hash256;
    accKey: NodeKey;
      ) =
  ## Append item to `fetchStorageFull` queue
  env.fetchStoragePart.del stoRoot    # Not a partial item anymore (if any)
  env.parkedStorage.excl accKey       # Un-park
  discard env.fetchStorageFull.append(
    stoRoot, SnapSlotsQueueItemRef(accKey: accKey))

proc storageQueueAppendFull*(
    env: SnapPivotRef;
    acc: AccountSlotsHeader;
      ) =
  ## variant of `storageQueueAppendFull()`
  env.storageQueueAppendFull(acc.storageRoot, acc.accKey)

proc storageQueueAppendFull*(
    env: SnapPivotRef;
    kvp: SnapSlotsQueuePair;
      ) =
  ## variant of `storageQueueAppendFull()`
  env.storageQueueAppendFull(kvp.key, kvp.data.accKey)


proc storageQueueAppendPartialBisect*(
    env: SnapPivotRef;
    acc: AccountSlotsHeader;
      ) =
  ## Append to partial queue so that the next fetch range is half the size of
  ## the current next range.

  # Fetch/rotate queue item
  let data = env.getOrMakePartial(acc.storageRoot, acc.accKey)[0]

  # Derive unprocessed ranges => into lower priority queue
  data.slots.unprocessed.clear()
  discard data.slots.unprocessed[1].merge(low(NodeTag),high(NodeTag))
  for iv in data.slots.processed.increasing:
    discard data.slots.unprocessed[1].reduce iv  # complements processed ranges

  # Prioritise half of first unprocessed range
  let rc = data.slots.unprocessed[1].ge()
  if rc.isErr:
    env.fetchStoragePart.del acc.storageRoot     # Oops, nothing to do
    return                                       # Done
  let halfTag = rc.value.minPt + ((rc.value.maxPt - rc.value.minPt) div 2)
  data.slots.unprocessed.merge(rc.value.minPt, halfTag)


proc storageQueueAppend*(
    env: SnapPivotRef;
    reqList: openArray[AccountSlotsHeader];
    subRange = none(NodeTagRange);            # For a partially fetched slot
      ) =
  for n,w in reqList:
    env.parkedStorage.excl w.accKey           # Un-park

    # Only last item (when `n+1 == reqList.len`) may be registered partial
    if w.subRange.isNone or n + 1 < reqList.len:
      env.storageQueueAppendFull w

    else:
      env.fetchStorageFull.del w.storageRoot

      let
        (data, hasItem) = env.getOrMakePartial(w.storageRoot, w.accKey)
        iv = w.subRange.unsafeGet

      # Register partial range
      if subRange.isSome:
        # The `subRange` is the original request, `iv` the uncompleted part
        let reqRange = subRange.unsafeGet
        if not hasItem:
          # Re-initialise book keeping
          discard data.slots.processed.merge(low(NodeTag),high(NodeTag))
          discard data.slots.processed.reduce reqRange
          data.slots.unprocessed.clear()

        # Calculate `reqRange - iv` which are the completed ranges
        let temp = NodeTagRangeSet.init()
        discard temp.merge reqRange
        discard temp.reduce iv

        # Update `processed` ranges by adding `reqRange - iv`
        for w in temp.increasing:
          discard data.slots.processed.merge w

        # Update `unprocessed` ranges
        data.slots.unprocessed.merge reqRange
        data.slots.unprocessed.reduce iv

      elif hasItem:
        # Restore unfetched request
        data.slots.unprocessed.merge iv

      else:
        # Makes no sense with a `leftOver` item
        env.storageQueueAppendFull w

# ------------------------------------------------------------------------------
# Public functions, make/create queue items
# ------------------------------------------------------------------------------

proc storageQueueGetOrMakePartial*(
    env: SnapPivotRef;
    stoRoot: Hash256;
    accKey: NodeKey;
      ): SnapSlotsQueueItemRef =
  ## Create record on `fetchStoragePart` or return existing one
  env.getOrMakePartial(stoRoot, accKey)[0]

proc storageQueueGetOrMakePartial*(
    env: SnapPivotRef;
    acc: AccountSlotsHeader;
      ): SnapSlotsQueueItemRef =
  ## Variant of `storageQueueGetOrMakePartial()`
  env.getOrMakePartial(acc.storageRoot, acc.accKey)[0]

# ------------------------------------------------------------------------------
# Public functions, fetch and remove queue items
# ------------------------------------------------------------------------------

proc storageQueueFetchFull*(
    ctx: SnapCtxRef;                   # Global context
    env: SnapPivotRef;                 # Current pivot environment
      ): (seq[AccountSlotsHeader],int,int) =
  ## Fetch a list of at most `fetchRequestStorageSlotsMax` full work items
  ## from the batch queue.
  ##
  ## This function walks through the items queue and collects work items where
  ## the hexary trie has not been fully or partially allocated on the database
  ## already. These collected items are returned as first item of the return
  ## code tuple.
  ##
  ## There will be a sufficient (but not necessary) quick check whether a
  ## partally allocated work item is complete, already. In which case it is
  ## removed from the queue. The number of removed items is returned as
  ## second item of the return code tuple.
  ##
  ## Otherwise, a partially allocated item is meoved to the partial queue. The
  ## number of items moved to the partial queue is returned as third item of
  ## the return code tuple.
  ##
  var
    rcList: seq[AccountSlotsHeader]
    nComplete = 0
    nPartial = 0

  noExceptionOops("getNextSlotItemsFull"):
    for kvp in env.fetchStorageFull.nextPairs:
      let
        getFn = ctx.data.snapDb.getStorageSlotsFn kvp.data.accKey
        rootKey = kvp.key.to(NodeKey)
        accItem = AccountSlotsHeader(
          accKey:      kvp.data.accKey,
          storageRoot: kvp.key)

      # This item will either be returned, discarded, or moved to the partial
      # queue subject for healing. So it will be removed from this queue.
      env.fetchStorageFull.del kvp.key           # OK to delete current link

      # Check whether the tree is fully empty
      if rootKey.ByteArray32.getFn.len == 0:
        # Collect for return
        rcList.add accItem
        env.parkedStorage.incl accItem.accKey    # Registerd as absent

        # Maximal number of items to fetch
        if fetchRequestStorageSlotsMax <= rcList.len:
          break
      else:
        # Check how much there is below the top level storage slots node. For
        # a small storage trie, this check will be exhaustive.
        let stats = getFn.hexaryInspectTrie(rootKey,
          suspendAfter = storageSlotsTrieInheritPerusalMax,
          maxDangling = 1)

        if stats.dangling.len == 0 and stats.resumeCtx.isNil:
          # This storage trie could be fully searched and there was no dangling
          # node. So it is complete and can be fully removed from the batch.
          nComplete.inc                          # Update for logging
        else:
          # This item becomes a partially available slot 
          #let data = env.storageQueueGetOrMakePartial accItem -- notused
          nPartial.inc                           # Update for logging

  (rcList, nComplete, nPartial)
          

proc storageQueueFetchPartial*(
    env: SnapPivotRef;
      ): Result[AccountSlotsHeader,void] =
  ## Get work item from the batch queue. This will typically return the full
  ## work item and remove it from the queue unless the parially completed
  ## range is fragmented.
  block findItem:
    for kvp in env.fetchStoragePart.nextPairs:
      # Extract range and return single item request queue
      let rc = kvp.data.slots.unprocessed.fetch(maxLen = high(UInt256))
      if rc.isOk:
        result = ok(AccountSlotsHeader(
          accKey:      kvp.data.accKey,
          storageRoot: kvp.key,
          subRange:    some rc.value))

        # Delete from batch queue if the `unprocessed` range set becomes empty
        # and the `processed` set is the complemet of `rc.value`.
        if kvp.data.slots.unprocessed.isEmpty and
           high(UInt256) - rc.value.len <= kvp.data.slots.processed.total:
          env.fetchStoragePart.del kvp.key
          env.parkedStorage.incl kvp.data.accKey # Temporarily parked
          return
        else:
          # Otherwise rotate queue
          break findItem
      # End for()

    return err()

  # Rotate queue item
  discard env.fetchStoragePart.lruFetch result.value.storageRoot

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
