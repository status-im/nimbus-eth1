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
  stew/[interval_set, keyed_queue],
  ../../db/select_backend,
  ../sync_desc,
  ./worker/[com/com_error, db/snapdb_desc, ticker],
  ./range_desc

{.push raises: [Defect].}

type
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
    slots*: SnapTrieRangeBatchRef      ## slots to fetch, nil => all slots
    inherit*: bool                     ## mark this trie seen already

  SnapTodoRanges* = array[2,NodeTagRangeSet]
    ## Pair of node range lists. The first entry must be processed first. This
    ## allows to coordinate peers working on different state roots to avoid
    ## ovelapping accounts as long as they fetch from the first entry.

  SnapTrieRangeBatch* = object
    ## `NodeTag` ranges to fetch, healing support
    unprocessed*: SnapTodoRanges       ## Range of slots not covered, yet
    checkNodes*: seq[Blob]             ## Nodes with prob. dangling child links
    missingNodes*: seq[NodeSpecs]      ## Dangling links to fetch and merge

  SnapTrieRangeBatchRef* = ref SnapTrieRangeBatch
    ## Referenced object, so it can be made optional for the storage
    ## batch list

  SnapHealingState* = enum
    ## State of healing process. The `HealerRunning` state indicates that
    ## dangling and/or missing nodes have been temprarily removed from the
    ## batch queue while processing.
    HealerIdle
    HealerRunning
    HealerDone

  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root

    # Accounts download
    fetchAccounts*: SnapTrieRangeBatch ## Set of accounts ranges to fetch
    accountsState*: SnapHealingState   ## All accounts have been processed

    # Storage slots download
    fetchStorageFull*: SnapSlotsQueue  ## Fetch storage trie for these accounts
    fetchStoragePart*: SnapSlotsQueue  ## Partial storage trie to com[plete
    storageDone*: bool                 ## Done with storage, block sync next

    # Info
    nAccounts*: uint64                 ## Imported # of accounts
    nSlotLists*: uint64                ## Imported # of account storage tries

  SnapPivotTable* = ##\
    ## LRU table, indexed by state root
    KeyedQueue[Hash256,SnapPivotRef]

  BuddyData* = object
    ## Per-worker local descriptor data extension
    errors*: ComErrorStatsRef          ## For error handling
    pivotFinder*: RootRef              ## Opaque object reference for sub-module
    pivotEnv*: SnapPivotRef            ## Environment containing state root

  CtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext          ## Random generator
    dbBackend*: ChainDB                ## Low level DB driver access (if any)
    pivotTable*: SnapPivotTable        ## Per state root environment
    pivotFinderCtx*: RootRef           ## Opaque object reference for sub-module
    snapDb*: SnapDbRef                 ## Accounts snapshot DB
    coveredAccounts*: NodeTagRangeSet  ## Derived from all available accounts

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
# Public helpers: SnapTodoRanges
# ------------------------------------------------------------------------------

proc init*(q: var SnapTodoRanges) =
  ## Populate node range sets with maximal range in the first range set
  q[0] = NodeTagRangeSet.init()
  q[1] = NodeTagRangeSet.init()
  discard q[0].merge(low(NodeTag),high(NodeTag))


proc merge*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Unconditionally merge the node range into the account ranges list
  discard q[0].reduce(iv)
  discard q[1].merge(iv)

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

# ------------------------------------------------------------------------------
# Public helpers: SlotsQueue
# ------------------------------------------------------------------------------

proc merge*(q: var SnapSlotsQueue; kvp: SnapSlotsQueuePair) =
  ## Append/prepend a queue item record into the batch queue.
  let
    reqKey = kvp.key
    rc = q.eq(reqKey)
  if rc.isOk:
    # Entry exists already
    let qData = rc.value
    if not qData.slots.isNil:
      # So this entry is not maximal and can be extended
      if kvp.data.slots.isNil:
        # Remove restriction for this entry and move it to the right end
        qData.slots = nil
        discard q.lruFetch(reqKey)
      else:
        # Merge argument intervals into target set
        for ivSet in kvp.data.slots.unprocessed:
          for iv in ivSet.increasing:
            discard qData.slots.unprocessed[0].reduce(iv)
            discard qData.slots.unprocessed[1].merge(iv)
  else:
    # Only add non-existing entries
    if kvp.data.slots.isNil:
      # Append full range to the right of the list
      discard q.append(reqKey, kvp.data)
    else:
      # Partial range, add healing support and interval
      discard q.unshift(reqKey, kvp.data)

proc merge*(q: var SnapSlotsQueue; fetchReq: AccountSlotsHeader) =
  ## Append/prepend a slot header record into the batch queue.
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
        discard q.lruFetch(reqKey)
      else:
        # Merge argument interval into target set
        let iv = fetchReq.subRange.unsafeGet
        discard qData.slots.unprocessed[0].reduce(iv)
        discard qData.slots.unprocessed[1].merge(iv)
  else:
    let reqData = SnapSlotsQueueItemRef(accKey: fetchReq.accKey)

    # Only add non-existing entries
    if fetchReq.subRange.isNone:
      # Append full range to the right of the list
      discard q.append(reqKey, reqData)
    else:
      # Partial range, add healing support and interval
      reqData.slots = SnapTrieRangeBatchRef()
      for n in 0 ..< reqData.slots.unprocessed.len:
        reqData.slots.unprocessed[n] = NodeTagRangeSet.init()
      discard reqData.slots.unprocessed[0].merge(fetchReq.subRange.unsafeGet)
      discard q.unshift(reqKey, reqData)

proc merge*(
    q: var SnapSlotsQueue;
    reqList: openArray[SnapSlotsQueuePair|AccountSlotsHeader]) =
  ## Variant fof `merge()` for a list argument
  for w in reqList:
    q.merge w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
