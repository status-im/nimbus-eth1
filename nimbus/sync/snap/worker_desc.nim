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
  std/hashes,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue, sorted_set],
  ../../db/select_backend,
  ../sync_desc,
  ./worker/com/com_error,
  ./worker/db/[hexary_desc, snapdb_desc, snapdb_pivot],
  ./worker/ticker,
  ./range_desc

{.push raises: [Defect].}

type
  SnapAccountsList* = SortedSet[NodeTag,Hash256]
    ## Sorted pair of `(account,state-root)` entries

  SnapSlotsQueue* = KeyedQueue[Hash256,SnapSlotsQueueItemRef]
    ## Handles list of storage slots data for fetch indexed by storage root.
    ##
    ## Typically, storage data requests cover the full storage slots trie. If
    ## there is only a partial list of slots to fetch, the queue entry is
    ## stored left-most for easy access.

  SnapSlotsQueuePair* = KeyedQueuePair[Hash256,SnapSlotsQueueItemRef]
    ## Key-value return code from `SnapSlotsQueue` handler

  SnapSlotsQueueItemRef* = ref object
    ## Storage slots request data. This entry is similar to `AccountSlotsHeader`
    ## where the optional `subRange` interval has been replaced by an interval
    ## range + healing support.
    accKey*: NodeKey                   ## Owner account
    slots*: SnapRangeBatchRef          ## slots to fetch, nil => all slots
    inherit*: bool                     ## mark this trie seen already

  SnapTodoRanges* = array[2,NodeTagRangeSet]
    ## Pair of sets of ``unprocessed`` node ranges that need to be fetched and
    ## integrated. The ranges in the first set must be handled with priority.
    ##
    ## This data structure is used for coordinating peers that run quasi
    ## parallel.

  SnapTodoNodes* = object
    ## Pair of node lists subject to swap-in and healing
    check*: seq[NodeSpecs]             ## Existing nodes, sub-trie unknown
    missing*: seq[NodeSpecs]           ## Top ref for sub-tries to be healed

  SnapRangeBatchRef* = ref object
    ## `NodeTag` ranges to fetch, healing support
    unprocessed*: SnapTodoRanges       ## Range of slots to be fetched
    processed*: NodeTagRangeSet        ## Node ranges definitely processed
    nodes*: SnapTodoNodes              ## Single nodes to double check
    resumeCtx*: TrieNodeStatCtxRef     ## State for resuming trie inpection
    lockTriePerusal*: bool             ## Only one process at a time

  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root

    # Accounts download coverage
    fetchAccounts*: SnapRangeBatchRef  ## Set of accounts ranges to fetch

    # Storage slots download
    fetchStorageFull*: SnapSlotsQueue  ## Fetch storage trie for these accounts
    fetchStoragePart*: SnapSlotsQueue  ## Partial storage trie to com[plete
    storageDone*: bool                 ## Done with storage, block sync next

    # Info
    nAccounts*: uint64                 ## Imported # of accounts
    nSlotLists*: uint64                ## Imported # of account storage tries

    # Mothballing, ready to be swapped into newer pivot record
    storageAccounts*: SnapAccountsList ## Accounts with missing stortage slots
    archived*: bool                    ## Not latest pivot, anymore

  SnapPivotTable* = KeyedQueue[Hash256,SnapPivotRef]
    ## LRU table, indexed by state root

  SnapRecoveryRef* = ref object
    ## Recovery context
    state*: SnapDbPivotRegistry        ## Saved recovery context state
    level*: int                        ## top level is zero

  BuddyData* = object
    ## Per-worker local descriptor data extension
    errors*: ComErrorStatsRef          ## For error handling
    pivotFinder*: RootRef              ## Opaque object reference for sub-module
    pivotEnv*: SnapPivotRef            ## Environment containing state root

  CtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext          ## Random generator
    dbBackend*: ChainDB                ## Low level DB driver access (if any)
    snapDb*: SnapDbRef                 ## Accounts snapshot DB

    # Pivot table
    pivotTable*: SnapPivotTable        ## Per state root environment
    pivotFinderCtx*: RootRef           ## Opaque object reference for sub-module
    coveredAccounts*: NodeTagRangeSet  ## Derived from all available accounts
    covAccTimesFull*: uint             ## # of 100% coverages
    recovery*: SnapRecoveryRef         ## Current recovery checkpoint/context
    noRecovery*: bool                  ## Ignore recovery checkpoints

    # Info
    ticker*: TickerRef                 ## Ticker, logger

  SnapBuddyRef* = BuddyRef[CtxData,BuddyData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[CtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hash*(a: SnapSlotsQueueItemRef): Hash =
  ## Table/KeyedQueue mixin
  cast[pointer](a).hash

proc hash*(a: Hash256): Hash =
  ## Table/KeyedQueue mixin
  a.data.hash

# ------------------------------------------------------------------------------
# Public helpers: coverage
# ------------------------------------------------------------------------------

proc pivotAccountsCoverage*(ctx: SnapCtxRef): float =
  ## Returns the accounts coverage factor
  ctx.data.coveredAccounts.fullFactor + ctx.data.covAccTimesFull.float

# ------------------------------------------------------------------------------
# Public helpers: SnapTodoRanges
# ------------------------------------------------------------------------------

proc init*(q: var SnapTodoRanges) =
  ## Populate node range sets with maximal range in the first range set. This
  ## kind of pair or interval sets is manages as follows:
  ## * As long as possible, fetch and merge back intervals on the first set.
  ## * If the first set is empty and some intervals are to be fetched, swap
  ##   first and second interval lists.
  ## That way, intervals from the first set are prioitised while the rest is
  ## is considered after the prioitised intervals are exhausted.
  q[0] = NodeTagRangeSet.init()
  q[1] = NodeTagRangeSet.init()
  discard q[0].merge(low(NodeTag),high(NodeTag))


proc merge*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Unconditionally merge the node range into the account ranges list.
  discard q[0].merge(iv)
  discard q[1].reduce(iv)

proc merge*(q: var SnapTodoRanges; minPt, maxPt: NodeTag) =
  ## Variant of `merge()`
  q.merge NodeTagRange.new(minPt, maxPt)


proc reduce*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Unconditionally remove the node range from the account ranges list
  discard q[0].reduce(iv)
  discard q[1].reduce(iv)

proc reduce*(q: var SnapTodoRanges; minPt, maxPt: NodeTag) =
  ## Variant of `reduce()`
  q.reduce NodeTagRange.new(minPt, maxPt)


iterator ivItems*(q: var SnapTodoRanges): NodeTagRange =
  ## Iterator over all list entries
  for ivSet in q:
    for iv in ivSet.increasing:
      yield iv


proc fetch*(q: var SnapTodoRanges; maxLen: UInt256): Result[NodeTagRange,void] =
  ## Fetch interval from node ranges with maximal size `maxLen`

  # Swap batch queues if the first one is empty
  if q[0].isEmpty:
    swap(q[0], q[1])

  # Fetch from first range list
  let rc = q[0].ge()
  if rc.isErr:
    return err()

  let
    val = rc.value
    iv = if 0 < val.len and val.len <= maxLen: val # val.len==0 => 2^256
         else: NodeTagRange.new(val.minPt, val.minPt + (maxLen - 1.u256))
  discard q[0].reduce(iv)
  ok(iv)


proc verify*(q: var SnapTodoRanges): bool =
  ## Verify consistency, i.e. that the two sets of ranges have no overlap.
  if q[0].chunks == 0 or q[1].chunks == 0:
    # At least one set is empty
    return true
  # So neither set is empty
  if q[0].total == 0 or q[1].total == 0:
    # At least one set is maximal and the other non-empty
    return false
  # So neither set is empty, not full
  let (a,b) = if q[0].chunks < q[1].chunks: (0,1) else: (1,0)
  for iv in q[a].increasing:
    if 0 < q[b].covered(iv):
      return false
  true

# ------------------------------------------------------------------------------
# Public helpers: SlotsQueue
# ------------------------------------------------------------------------------

proc merge*(q: var SnapSlotsQueue; kvp: SnapSlotsQueuePair) =
  ## Append/prepend a queue item record into the batch queue.
  let
    reqKey = kvp.key
    rc = q.eq(reqKey)
  if rc.isErr:
    # Append to list
    discard q.append(reqKey, kvp.data)
  else:
    # Entry exists already
    let qData = rc.value
    if not qData.slots.isNil:
      # So this entry is not maximal and can be extended
      if kvp.data.slots.isNil:
        # Remove restriction for this entry and move it to the right end
        qData.slots = nil
        discard q.lruFetch reqKey
      else:
        # Merge argument intervals into target set
        for ivSet in kvp.data.slots.unprocessed:
          for iv in ivSet.increasing:
            qData.slots.unprocessed.reduce iv

proc merge*(q: var SnapSlotsQueue; fetchReq: AccountSlotsHeader) =
  ## Append/prepend a slot header record into the batch queue. If there is
  ## a range merger, the argument range will be sortred in a way so that it
  ## is processed separately with highest priority.
  let
    reqKey = fetchReq.storageRoot
    rc = q.eq(reqKey)
  if rc.isOk:
    # Entry exists already
    let qData = rc.value
    if not qData.slots.isNil:
      # So this entry is not maximal and can be extended
      if fetchReq.subRange.isNone:
        # Remove restriction for this entry and move it to the right end
        qData.slots = nil
        discard q.lruFetch reqKey
      else:
        # Merge argument interval into target separated from the already
        # existing sets (note that this works only for the last set)
        for iv in qData.slots.unprocessed[0].increasing:
          # Move all to second set
          discard qData.slots.unprocessed[1].merge iv
        # Clear first set and add argument range
        qData.slots.unprocessed[0].clear()
        qData.slots.unprocessed.merge fetchReq.subRange.unsafeGet

  elif fetchReq.subRange.isNone:
    # Append full range to the list
    discard q.append(reqKey, SnapSlotsQueueItemRef(
      accKey: fetchReq.accKey))

  else:
    # Partial range, add healing support and interval
    var unprocessed = [NodeTagRangeSet.init(), NodeTagRangeSet.init()]
    discard unprocessed[0].merge(fetchReq.subRange.unsafeGet)
    discard q.append(reqKey, SnapSlotsQueueItemRef(
      accKey: fetchReq.accKey,
      slots:  SnapRangeBatchRef(
        unprocessed: unprocessed,
        processed:   NodeTagRangeSet.init())))

proc merge*(
    q: var SnapSlotsQueue;
    reqList: openArray[SnapSlotsQueuePair|AccountSlotsHeader]) =
  ## Variant fof `merge()` for a list argument
  for w in reqList:
    q.merge w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
