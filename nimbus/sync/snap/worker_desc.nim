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

const
  snapRequestBytesLimit* = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

  minPivotBlockDistance* = 128
    ## The minimal depth of two block headers needed to activate a new state
    ## root pivot.
    ##
    ## Effects on assembling the state via `snap/1` protocol:
    ##
    ## * A small value of this constant increases the propensity to update the
    ##   pivot header more often. This is so because each new peer negoiates a
    ##   pivot block number at least the current one.
    ##
    ## * A large value keeps the current pivot more stable but some experiments
    ##   suggest that the `snap/1` protocol is answered only for later block
    ##   numbers (aka pivot blocks.) So a large value tends to keep the pivot
    ##   farther away from the chain head.
    ##
    ##   Note that 128 is the magic distance for snapshots used by *Geth*.

  healAccountsTrigger* = 0.95
    ## Apply accounts healing if the global snap download coverage factor
    ## exceeds this setting. The global coverage factor is derived by merging
    ## all account ranges retrieved for all pivot state roots (see
    ## `coveredAccounts` in `CtxData`.)
    ##
    ## A small value of this constant leads to early healing. This produces
    ## stray leaf account records so fragmenting larger intervals of missing
    ## account ranges. This in turn leads to smaller but more range requests
    ## over the network. More requests might be a disadvantage if peers only
    ## serve a maximum number requests (rather than data.)

  healSlorageSlotsTrigger* = 0.70
    ## Consider per account storage slost healing if this particular sub-trie
    ## has reached this factor of completeness

  maxStoragesFetch* = 5 * 1024
    ## Maximal number of storage tries to fetch with a single message.

  maxStoragesHeal* = 32
    ## Maximal number of storage tries to to heal in a single batch run.

  maxTrieNodeFetch* = 1024
    ## Informal maximal number of trie nodes to fetch at once. This is nor
    ## an official limit but found on several implementations (e.g. geth.)
    ##
    ## Resticting the fetch list length early allows to better paralellise
    ## healing.

  maxHealingLeafPaths* = 1024
    ## Retrieve this many leave nodes with proper 32 bytes path when inspecting
    ## for dangling nodes. This allows to run healing paralell to accounts or
    ## storage download without requestinng an account/storage slot found by
    ## healing again with the download.

  noPivotEnvChangeIfComplete* = true
    ## If set `true`, new peers will not change the pivot even if the
    ## negotiated pivot would be newer. This should be the default.

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

  SnapSlotsSet* = HashSet[SnapSlotsQueueItemRef]
    ## Ditto but without order, to be used as veto set

  SnapAccountRanges* = array[2,NodeTagRangeSet]
    ## Pair of account hash range lists. The first entry must be processed
    ## first. This allows to coordinate peers working on different state roots
    ## to avoid ovelapping accounts as long as they fetch from the first entry.

  SnapTrieRangeBatch* = object
    ## `NodeTag` ranges to fetch, healing support
    unprocessed*: SnapAccountRanges    ## Range of slots not covered, yet
    checkNodes*: seq[Blob]             ## Nodes with prob. dangling child links
    missingNodes*: seq[NodeSpecs]      ## Dangling links to fetch and merge

  SnapTrieRangeBatchRef* = ref SnapTrieRangeBatch
    ## Referenced object, so it can be made optional for the storage
    ## batch list


  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root

    # Accounts download
    fetchAccounts*: SnapTrieRangeBatch ## Set of accounts ranges to fetch
    accountsDone*: bool                ## All accounts have been processed

    # Storage slots download
    fetchStorage*: SnapSlotsQueue      ## Fetch storage for these accounts
    serialSync*: bool                  ## Done with storage, block sync next

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

static:
  doAssert healAccountsTrigger < 1.0 # larger values make no sense

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
# Public helpers
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
