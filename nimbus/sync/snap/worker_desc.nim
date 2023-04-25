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
  std/hashes,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue, sorted_set],
  ../../db/select_backend,
  ../misc/ticker,
  ../sync_desc,
  ./worker/get/get_error,
  ./worker/db/[snapdb_desc, snapdb_pivot],
  ./range_desc

export
  sync_desc # worker desc prototype

type
  SnapAccountsList* = SortedSet[NodeTag,Hash256]
    ## Sorted pair of `(account,state-root)` entries

  SnapSlotsQueue* = KeyedQueue[Hash256,SnapSlotsQueueItemRef]
    ## Handles list of storage slots data to fetch, indexed by storage root.
    ##
    ## Typically, storage data requests cover the full storage slots trie. If
    ## there is only a partial list of slots to fetch, the queue entry is
    ## stored left-most for easy access.

  SnapSlotsQueueItemRef* = ref object
    ## Storage slots request data. This entry is similar to `AccountSlotsHeader`
    ## where the optional `subRange` interval has been replaced by an interval
    ## range + healing support.
    accKey*: NodeKey                   ## Owner account
    slots*: SnapRangeBatchRef          ## Clots to fetch, nil => all slots

  SnapCtraQueue* = KeyedQueue[Hash256,NodeKey]
    ## Handles hash key list of contract data to fetch with accounts associated

  SnapTodoRanges* = array[2,NodeTagRangeSet]
    ## Pair of sets of ``unprocessed`` node ranges that need to be fetched and
    ## integrated. The ranges in the first set must be handled with priority.
    ##
    ## This data structure is used for coordinating peers that run quasi
    ## parallel.

  SnapRangeBatchRef* = ref object
    ## `NodeTag` ranges to fetch, healing support
    unprocessed*: SnapTodoRanges       ## Range of slots to be fetched
    processed*: NodeTagRangeSet        ## Node ranges definitely processed

  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root

    # Accounts download coverage
    fetchAccounts*: SnapRangeBatchRef  ## Set of accounts ranges to fetch

    # Contract code queue
    fetchContracts*: SnapCtraQueue     ## Contacts to fetch & store

    # Storage slots download
    fetchStorageFull*: SnapSlotsQueue  ## Fetch storage trie for these accounts
    fetchStoragePart*: SnapSlotsQueue  ## Partial storage trie to com[plete
    parkedStorage*: HashSet[NodeKey]   ## Storage batch items in use

    # Info
    nAccounts*: uint64                 ## Imported # of accounts
    nSlotLists*: uint64                ## Imported # of account storage tries
    nContracts*: uint64                ## Imported # of contract code sets

    # Checkponting
    savedFullPivotOk*: bool            ## This fully completed pivot was saved

    # Mothballing, ready to be swapped into newer pivot record
    storageAccounts*: SnapAccountsList ## Accounts with missing storage slots
    archived*: bool                    ## Not latest pivot, anymore

  SnapPivotTable* = KeyedQueue[Hash256,SnapPivotRef]
    ## LRU table, indexed by state root

  SnapRecoveryRef* = ref object
    ## Recovery context
    state*: SnapDbPivotRegistry        ## Saved recovery context state
    level*: int                        ## top level is zero

  SnapBuddyData* = object
    ## Per-worker local descriptor data extension
    errors*: GetErrorStatsRef          ## For error handling
    full*: RootRef                     ## Peer local full sync descriptor

  SnapSyncPassType* = enum
    ## Current sync mode, after a snapshot has been downloaded, the system
    ## proceeds with full sync.
    SnapSyncMode = 0                   ## Start mode
    FullSyncMode

  SnapSyncPass* = object
    ## Full specs for all sync modes. This table must be held in the main
    ## descriptor and initialised at run time. The table values are opaque
    ## and will be specified in the worker module(s).
    active*: SnapSyncPassType
    tab*: array[SnapSyncPassType,RootRef]

  SnapCtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext          ## Random generator
    dbBackend*: ChainDB                ## Low level DB driver access (if any)
    snapDb*: SnapDbRef                 ## Accounts snapshot DB

    # Info
    enableTicker*: bool                ## Advisary, extra level of gossip
    ticker*: TickerRef                 ## Ticker, logger descriptor

    # Snap/full mode muliplexing
    syncMode*: SnapSyncPass            ## Sync mode methods & data

    # Snap sync parameters, pivot table
    pivotTable*: SnapPivotTable        ## Per state root environment
    completePivot*: SnapPivotRef       ## Start full sync from here
    beaconHeader*: BlockHeader         ## Running on beacon chain
    coveredAccounts*: NodeTagRangeSet  ## Derived from all available accounts
    covAccTimesFull*: uint             ## # of 100% coverages
    recovery*: SnapRecoveryRef         ## Current recovery checkpoint/context

    # Full sync continuation parameters
    fullHeader*: Option[BlockHeader]   ## Start full sync from here
    full*: RootRef                     ## Global full sync descriptor

  SnapBuddyRef* = BuddyRef[SnapCtxData,SnapBuddyData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData]
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

proc init*(q: var SnapTodoRanges; clear = false) =
  ## Populate node range sets with maximal range in the first range set. This
  ## kind of pair or interval sets is managed as follows:
  ## * As long as possible, fetch and merge back intervals on the first set.
  ## * If the first set is empty and some intervals are to be fetched, swap
  ##   first and second interval lists.
  ## That way, intervals from the first set are prioitised while the rest is
  ## is considered after the prioitised intervals are exhausted.
  q[0] = NodeTagRangeSet.init()
  q[1] = NodeTagRangeSet.init()
  if not clear:
    discard q[0].merge FullNodeTagRange

proc clear*(q: var SnapTodoRanges) =
  ## Reset argument range sets empty.
  q[0].clear()
  q[1].clear()


proc merge*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Unconditionally merge the node range into the account ranges list.
  discard q[0].merge(iv)
  discard q[1].reduce(iv)

proc mergeSplit*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Ditto w/priorities partially reversed
  if iv.len == 1:
    discard q[0].reduce iv
    discard q[1].merge iv
  else:
    let
      # note that (`iv.len` == 0) => (`iv` == `FullNodeTagRange`)
      midPt = iv.minPt + ((iv.maxPt - iv.minPt) shr 1)
      iv1 = NodeTagRange.new(iv.minPt, midPt)
      iv2 = NodeTagRange.new(midPt + 1.u256, iv.maxPt)
    discard q[0].reduce iv1
    discard q[1].merge iv1
    discard q[0].merge iv2
    discard q[1].reduce iv2


proc reduce*(q: var SnapTodoRanges; iv: NodeTagRange) =
  ## Unconditionally remove the node range from the account ranges list
  discard q[0].reduce(iv)
  discard q[1].reduce(iv)


iterator ivItems*(q: var SnapTodoRanges): NodeTagRange =
  ## Iterator over all list entries
  for ivSet in q:
    for iv in ivSet.increasing:
      yield iv


proc fetch*(q: var SnapTodoRanges; maxLen = 0.u256): Result[NodeTagRange,void] =
  ## Fetch interval from node ranges with maximal size `maxLen`, where
  ## `0.u256` is interpreted as `2^256`.

  # Swap batch queues if the first one is empty
  if q[0].isEmpty:
    swap(q[0], q[1])

  # Fetch from first range list
  let rc = q[0].ge()
  if rc.isErr:
    return err()

  let
    jv = rc.value
    iv = block:
      if maxLen == 0 or (0 < jv.len and jv.len <= maxLen):
        jv
      else:
        # Note that either:
        #   (`jv.len` == 0)  => (`jv` == `FullNodeTagRange`) => `jv.minPt` == 0
        # or
        #   (`maxLen` < `jv.len`) => (`jv.minPt`+`maxLen` <= `jv.maxPt`)
        NodeTagRange.new(jv.minPt, jv.minPt + maxLen)

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
# End
# ------------------------------------------------------------------------------
