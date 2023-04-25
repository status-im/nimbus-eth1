# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sets,
  chronicles,
  eth/common, # p2p],
  stew/[interval_set, keyed_queue],
  "../../../.."/[constants, range_desc],
  ../../../db/[hexary_inspect, snapdb_storage_slots],
  ../snap_pass_desc

logScope:
  topics = "snap-slots"

type
  StoQuSlotsKVP* = KeyedQueuePair[Hash256,SnapPassSlotsQItemRef]
    ## Key-value return code from `SnapSlotsQueue` handler

  StoQuPartialSlotsQueue = object
    ## Return type for `getOrMakePartial()`
    stoQu: SnapPassSlotsQItemRef
    isCompleted: bool

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage queue " & info

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullPC3

proc `$`(tr: SnapPassTodoRanges): string =
  tr.fullPC3

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updatePartial(
    env: SnapPassPivotRef;                  # Current pivot environment
    req: AccountSlotsChanged;               # Left over account data
      ): bool =                             # List entry was added
  ## Update the range of account argument `req` to the partial slot ranges
  ## queue.
  ##
  ## The function returns `true` if a new list entry was added.
  let
    accKey = req.account.accKey
    stoRoot = req.account.storageRoot
    noFullEntry = env.fetchStorageFull.delete(stoRoot).isErr
    iv = req.account.subRange.get(otherwise = FullNodeTagRange)
    jv = req.newRange.get(otherwise = FullNodeTagRange)
    (slots, newEntry, newPartEntry) = block:
      let rc = env.fetchStoragePart.lruFetch stoRoot
      if rc.isOk:
        (rc.value.slots, false, false)
      else:
        # New entry
        let
          stoSlo = SnapPassRangeBatchRef(processed: NodeTagRangeSet.init())
          stoItem = SnapPassSlotsQItemRef(accKey: accKey, slots: stoSlo)
        discard env.fetchStoragePart.append(stoRoot, stoItem)
        stoSlo.unprocessed.init(clear = true)

        # Initalise ranges
        var newItem = false
        if iv == FullNodeTagRange:
          # New record (probably was a full range, before)
          stoSlo.unprocessed.mergeSplit FullNodeTagRange
          newItem = noFullEntry
        else:
          # Restore `processed` range, `iv` was the left over.
          discard stoSlo.processed.merge FullNodeTagRange
          discard stoSlo.processed.reduce iv
        (stoSlo, newItem, true)

  # Remove delta state relative to original state
  if iv != jv:
    # Calculate `iv - jv`
    let ivSet = NodeTagRangeSet.init()
    discard ivSet.merge iv                  # Previous range
    discard ivSet.reduce jv                 # Left over range

    # Update `processed` by delta range
    for w in ivSet.increasing:
      discard slots.processed.merge w

    # Update left over
    slots.unprocessed.merge jv              # Left over range

  when extraTraceMessages:
    trace logTxt "updated partially", accKey, iv, jv,
      processed=slots.processed, unprocessed=slots.unprocessed,
      noFullEntry, newEntry, newPartEntry

  env.parkedStorage.excl accKey             # Un-park (if any)
  newEntry


proc appendPartial(
    env: SnapPassPivotRef;                  # Current pivot environment
    acc: AccountSlotsHeader;                # Left over account data
    splitMerge: bool;                       # Bisect or straight merge
      ): bool =                             # List entry was added
  ## Append to partial queue. The argument range of `acc` is split so that
  ## the next request of this range will result in the right most half size
  ## of this very range.
  ##
  ## The function returns `true` if a new list entry was added.
  let
    accKey = acc.accKey
    stoRoot = acc.storageRoot
    notFull = env.fetchStorageFull.delete(stoRoot).isErr
    iv = acc.subRange.get(otherwise = FullNodeTagRange)
    rc = env.fetchStoragePart.lruFetch acc.storageRoot
    (slots,newEntry) = block:
      if rc.isOk:
        (rc.value.slots, false)
      else:
        # Restore missing range
        let
          stoSlo = SnapPassRangeBatchRef(processed: NodeTagRangeSet.init())
          stoItem = SnapPassSlotsQItemRef(accKey: accKey, slots: stoSlo)
        discard env.fetchStoragePart.append(stoRoot, stoItem)
        stoSlo.unprocessed.init(clear = true)
        discard stoSlo.processed.merge FullNodeTagRange
        discard stoSlo.processed.reduce iv
        (stoSlo, notFull)

  if splitMerge:
    slots.unprocessed.mergeSplit iv
  else:
    slots.unprocessed.merge iv

  when extraTraceMessages:
    trace logTxt "merged partial", splitMerge, accKey, iv,
      processed=slots.processed, unprocessed=slots.unprocessed, newEntry

  env.parkedStorage.excl accKey             # Un-park (if any)
  newEntry


proc reducePartial(
    env: SnapPassPivotRef;                  # Current pivot environment
    acc: AccountSlotsHeader;                # Left over account data
      ): bool =                             # List entry was removed
  ## Reduce range from partial ranges list.
  ##
  ## The function returns `true` if a list entry was removed.
  # So `iv` was not the full range in which case all of `iv` was fully
  # processed and there is nothing left.
  let
    accKey = acc.accKey
    stoRoot = acc.storageRoot
    notFull = env.fetchStorageFull.delete(stoRoot).isErr
    iv = acc.subRange.get(otherwise = FullNodeTagRange)
    rc = env.fetchStoragePart.lruFetch stoRoot

  var entryRemoved = false
  if rc.isErr:
    # This was the last missing range anyway. So there is no need to
    # re-insert this entry.
    entryRemoved = true                     # Virtually deleted
    when extraTraceMessages:
      trace logTxt "reduced partial, discarded", accKey, iv, entryRemoved
  else:
    let slots = rc.value.slots
    discard slots.processed.merge iv

    if slots.processed.isFull:
      env.fetchStoragePart.del stoRoot
      result = true
      when extraTraceMessages:
        trace logTxt "reduced partial, deleted", accKey, iv, entryRemoved
    else:
      slots.unprocessed.reduce iv
      when extraTraceMessages:
        trace logTxt "reduced partial, completed", accKey, iv,
          processed=slots.processed, unprocessed=slots.unprocessed,
          entryRemoved

  env.parkedStorage.excl accKey             # Un-park (if any)
  entryRemoved

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc storageQueueTotal*(env: SnapPassPivotRef): int =
  ## Total number of entries on the storage queues, including parked ones.
  env.fetchStorageFull.len + env.fetchStoragePart.len + env.parkedStorage.len

proc storageQueueAvail*(env: SnapPassPivotRef): int =
  ## Number of available entries on the storage queues
  env.fetchStorageFull.len + env.fetchStoragePart.len

# ------------------------------------------------------------------------------
# Public functions, append queue items
# ------------------------------------------------------------------------------

proc storageQueueAppendFull*(
    env: SnapPassPivotRef;
    stoRoot: Hash256;
    accKey: NodeKey;
      ): bool
      {.discardable.} =
  ## Append item to `fetchStorageFull` queue. This undoes the effect of the
  ## function `storageQueueFetchFull()`. The function returns `true` if
  ## a new entry was added.
  let
    notPart = env.fetchStoragePart.delete(stoRoot).isErr
    stoItem = SnapPassSlotsQItemRef(accKey: accKey)
  env.parkedStorage.excl accKey             # Un-park (if any)
  env.fetchStorageFull.append(stoRoot, stoItem) and notPart

proc storageQueueAppendFull*(
    env: SnapPassPivotRef;
    acc: AccountSlotsHeader;
      ): bool
      {.discardable.} =
  ## Variant of `storageQueueAppendFull()`
  env.storageQueueAppendFull(acc.storageRoot, acc.accKey)

proc storageQueueAppendPartialSplit*(
    env: SnapPassPivotRef;                  # Current pivot environment
    acc: AccountSlotsHeader;                # Left over account data
      ): bool
      {.discardable.} =
  ## Merge slot range back into partial queue. This undoes the effect of the
  ## function `storageQueueFetchPartial()` with the additional feature that
  ## the argument range of `acc` is split. So some next range request for this
  ## account will result in the right most half size of this very range just
  ## inserted.
  ##
  ## The function returns `true` if a new entry was added.
  env.appendPartial(acc, splitMerge=true)

proc storageQueueAppendPartialSplit*(
    env: SnapPassPivotRef;                  # Current pivot environment
    req: openArray[AccountSlotsHeader];     # List of entries to push back
      ) =
  ## Variant of `storageQueueAppendPartialSplit()`
  for w in req:
    discard env.appendPartial(w, splitMerge=true)

proc storageQueueAppend*(
    env: SnapPassPivotRef;                  # Current pivot environment
    req: openArray[AccountSlotsHeader];     # List of entries to push back
      ) =
  ## Append a job list of ranges. This undoes the effect of either function
  ## `storageQueueFetchFull()` or `storageQueueFetchPartial()`.
  for w in req:
    let iv = w.subRange.get(otherwise = FullNodeTagRange)
    if iv == FullNodeTagRange:
      env.storageQueueAppendFull w
    else:
      discard env.appendPartial(w, splitMerge=false)

proc storageQueueAppend*(
    env: SnapPassPivotRef;                  # Current pivot environment
    kvp: StoQuSlotsKVP;                     # List of entries to push back
      ) =
  ## Insert back a full administrative queue record. This function is typically
  ## used after a record was unlinked vis `storageQueueUnlinkPartialItem()`.
  let accKey = kvp.data.accKey
  env.parkedStorage.excl accKey             # Un-park (if any)

  if kvp.data.slots.isNil:
    env.fetchStoragePart.del kvp.key        # Sanitise data
    discard env.fetchStorageFull.append(kvp.key, kvp.data)

    when extraTraceMessages:
      trace logTxt "re-queued full", accKey
  else:
    env.fetchStorageFull.del kvp.key        # Sanitise data

    let rc = env.fetchStoragePart.eq kvp.key
    if rc.isErr:
      discard env.fetchStoragePart.append(kvp.key, kvp.data)

      when extraTraceMessages:
        trace logTxt "re-queued partial",
          processed=kvp.data.slots.processed,
          unprocessed=kvp.data.slots.unprocessed, accKey
    else:
      # Merge `processed` ranges
      for w in kvp.data.slots.processed.increasing:
        discard  rc.value.slots.processed.merge w

      # Intersect `unprocessed` ranges
      for w in kvp.data.slots.unprocessed.ivItems:
         rc.value.slots.unprocessed.reduce w

      when extraTraceMessages:
        trace logTxt "re-merged partial",
          processed=kvp.data.slots.processed,
          unprocessed=kvp.data.slots.unprocessed, accKey

# ------------------------------------------------------------------------------
# Public functions, modify/update/remove queue items
# ------------------------------------------------------------------------------

proc storageQueueUpdate*(
    env: SnapPassPivotRef;                  # Current pivot environment
    req: openArray[AccountSlotsChanged];    # List of entries to push back
    ignore: HashSet[NodeKey];               # Ignore accounts with these keys
      ): (int,int) =                        # Added, removed
  ## Similar to `storageQueueAppend()`, this functions appends account header
  ## entries back into the storage queues. Different to `storageQueueAppend()`,
  ## this function is aware of changes after partial downloads from the network.
  ##
  ## The function returns the tuple `(added, removed)` reflecting the numbers
  ## of changed list items (accumulated for partial and full range lists.)
  for w in req:
    if w.account.accKey notin ignore:
      let
        iv = w.account.subRange.get(otherwise = FullNodeTagRange)
        jv = w.newRange.get(otherwise = FullNodeTagRange)
      if jv != FullNodeTagRange:
        # So `jv` is some rest after processing. Typically this entry is
        # related to partial range response message that came with a proof.
        if env.updatePartial w:
          result[0].inc
        when extraTraceMessages:
          trace logTxt "update/append partial", accKey=w.account.accKey,
            iv, jv, nAdded=result[0], nRemoved=result[1]
      elif jv == iv:
        if env.storageQueueAppendFull w.account:
          result[0].inc
        #when extraTraceMessages:
        #  trace logTxt "update/append full", accKey=w.account.accKey,
        #    nAdded=result[0], nRemoved=result[1]t
      else:
        if env.reducePartial w.account:
          result[1].inc
        when extraTraceMessages:
          trace logTxt "update/reduce partial", accKey=w.account.accKey,
            iv, jv, nAdded=result[0], nRemoved=result[1]

# ------------------------------------------------------------------------------
# Public functions, fetch/remove queue items
# ------------------------------------------------------------------------------

proc storageQueueFetchFull*(
    ctx: SnapCtxRef;                   # Global context
    env: SnapPassPivotRef;             # Current pivot environment
    ignore: HashSet[NodeKey];          # Ignore accounts with these keys
      ): seq[AccountSlotsHeader] =
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
  noExceptionOops("getNextSlotItemsFull"):
    for kvp in env.fetchStorageFull.nextPairs:
      if kvp.data.accKey notin ignore:
        let
          getFn = ctx.pool.snapDb.getStorageSlotsFn kvp.data.accKey
          rootKey = kvp.key.to(NodeKey)
          accItem = AccountSlotsHeader(
            accKey:      kvp.data.accKey,
            storageRoot: kvp.key)

        # This item will eventuallly be returned, discarded, or moved to the
        # partial queue (also subject for healing.) So it will be removed from
        # the full range lists queue.
        env.fetchStorageFull.del kvp.key           # OK to delete current link

        # Check whether the database trie is empty. Otherwise the sub-trie is
        # at least partially allocated.
        if rootKey.ByteArray32.getFn.len == 0:
          # Collect for return
          result.add accItem
          env.parkedStorage.incl accItem.accKey    # Registerd as absent

          # Maximal number of items to fetch
          if fetchRequestStorageSlotsMax <= result.len:
            break # stop here
        else:
          # Check how much there is below the top level storage slots node. For
          # a small storage trie, this check will be exhaustive.
          let stats = getFn.hexaryInspectTrie(rootKey,
            suspendAfter = storageSlotsTrieInheritPerusalMax,
            maxDangling = 1)

          if stats.dangling.len == 0 and stats.resumeCtx.isNil:
            # This storage trie could be fully searched and there was no
            # dangling node. So it is complete and can be considered done.
            # It can be left removed from the batch queue.
            env.nSlotLists.inc                     # Update for logging
          else:
            # This item must be treated as a partially available slot
            env.storageQueueAppendPartialSplit accItem

proc storageQueueFetchPartial*(
    ctx: SnapCtxRef;                   # Global context (unused here)
    env: SnapPassPivotRef;             # Current pivot environment
    ignore: HashSet[NodeKey];          # Ignore accounts with these keys
      ): seq[AccountSlotsHeader] =     # At most one item
  ## Get work item from the batch queue. This will typically return the full
  ## work item and remove it from the queue unless the parially completed
  ## range is fragmented.
  for kvp in env.fetchStoragePart.nextPairs:
    # Extract range and return single item request queue
    let
      slots = kvp.data.slots
      accKey = kvp.data.accKey
      accepted = accKey notin ignore
    if accepted:
      let rc = slots.unprocessed.fetch()
      if rc.isOk:
        let reqItem = AccountSlotsHeader(
          accKey:      accKey,
          storageRoot: kvp.key,
          subRange:    some rc.value)

        # Delete from batch queue if the `unprocessed` range has become empty.
        if slots.unprocessed.isEmpty and
           high(UInt256) - rc.value.len <= slots.processed.total:
          # If this is all the rest, the record can be deleted from the todo
          # list. If not fully downloaded at a later stage, a new record will
          # be created on-the-fly.
          env.parkedStorage.incl accKey            # Temporarily parked
          env.fetchStoragePart.del kvp.key         # Last one not needed
        else:
          # Otherwise accept and update/rotate queue. Note that `lruFetch`
          # does leave the item on the queue.
          discard env.fetchStoragePart.lruFetch reqItem.storageRoot

        when extraTraceMessages:
          trace logTxt "fetched partial",
            processed=slots.processed, unprocessed=slots.unprocessed,
            accKey, iv=rc.value
        return @[reqItem] # done

    when extraTraceMessages:
      trace logTxt "rejected partial", accepted,
        processed=slots.processed, unprocessed=slots.unprocessed, accKey
    # End for()

proc storageQueueUnlinkPartialItem*(
    env: SnapPassPivotRef;             # Current pivot environment
    ignore: HashSet[NodeKey];          # Ignore accounts with these keys
      ): Result[StoQuSlotsKVP,void] =
  ## Fetch an item from the partial list. This item will be removed from the
  ## list and ca be re-queued via `storageQueueAppend()`.
  for kvp in env.fetchStoragePart.nextPairs:
    # Extract range and return single item request queue
    let
      accKey = kvp.data.accKey
      accepted = accKey notin ignore
    if accepted:
      env.parkedStorage.incl accKey                # Temporarily parked
      env.fetchStoragePart.del kvp.key             # Last one not needed

      when extraTraceMessages:
        trace logTxt "unlink partial item", processed=kvp.data.slots.processed,
          unprocessed=kvp.data.slots.unprocessed, accKey
      return ok(kvp) # done

    when extraTraceMessages:
      trace logTxt "unlink partial skip", accepted,
        processed=kvp.data.slots.processed,
        unprocessed=kvp.data.slots.unprocessed, accKey
    # End for()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
