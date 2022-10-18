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
  std/[hashes, sequtils, strutils],
  eth/[common/eth_types, p2p],
  stew/[byteutils, interval_set, keyed_queue],
  "../.."/[constants, db/select_backend],
  ".."/[sync_desc, types],
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

  backPivotBlockDistance* = 64
    ## When a pivot header is found, move pivot back `backPivotBlockDistance`
    ## blocks so that the pivot is guaranteed to have some distance from the
    ## chain head.
    ##
    ## Set `backPivotBlockDistance` to zero for disabling this feature.

  backPivotBlockThreshold* = backPivotBlockDistance + minPivotBlockDistance
    ## Ignore `backPivotBlockDistance` unless the current block number is
    ## larger than this constant (which must be at least
    ## `backPivotBlockDistance`.)

  healAccountsTrigger* = 0.95
    ## Apply accounts healing if the global snap download coverage factor
    ## exceeds this setting. The global coverage factor is derived by merging
    ## all account ranges retrieved for all pivot state roots (see
    ## `coveredAccounts` in `CtxData`.)

  healSlorageSlotsTrigger* = 0.70
    ## Consider per account storage slost healing if this particular sub-trie
    ## has reached this factor of completeness

  maxStoragesFetch* = 512
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

  # -------

  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  WorkerSeenBlocks = KeyedQueue[NodeKey,BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  SnapSlotsQueue* = KeyedQueue[NodeKey,SnapSlotQueueItemRef]
    ## Handles list of storage slots data for fetch indexed by storage root.
    ##
    ## Typically, storage data requests cover the full storage slots trie. If
    ## there is only a partial list of slots to fetch, the queue entry is
    ## stored left-most for easy access.

  SnapSlotsQueuePair* = KeyedQueuePair[NodeKey,SnapSlotQueueItemRef]
    ## Key-value return code from `SnapSlotsQueue` handler

  SnapSlotQueueItemRef* = ref object
    ## Storage slots request data. This entry is similar to `AccountSlotsHeader`
    ## where the optional `subRange` interval has been replaced by an interval
    ## range + healing support.
    accHash*: Hash256                  ## Owner account, maybe unnecessary
    slots*: SnapTrieRangeBatchRef      ## slots to fetch, nil => all slots
    inherit*: bool                     ## mark this trie seen already

  SnapSlotsSet* = HashSet[SnapSlotQueueItemRef]
    ## Ditto but without order, to be used as veto set

  SnapAccountRanges* = array[2,NodeTagRangeSet]
    ## Pair of account hash range lists. The first entry must be processed
    ## first. This allows to coordinate peers working on different state roots
    ## to avoid ovelapping accounts as long as they fetch from the first entry.

  SnapTrieRangeBatch* = object
    ## `NodeTag` ranges to fetch, healing support
    unprocessed*: SnapAccountRanges    ## Range of slots not covered, yet
    checkNodes*: seq[Blob]             ## Nodes with prob. dangling child links
    missingNodes*: seq[Blob]           ## Dangling links to fetch and merge

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
    nAccounts*: uint64                 ## Number of accounts imported
    nStorage*: uint64                  ## Number of storage spaces imported

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
    seenBlock: WorkerSeenBlocks        ## Temporary, debugging, pretty logs
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
  doAssert backPivotBlockDistance <= backPivotBlockThreshold

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hash*(a: SnapSlotQueueItemRef): Hash =
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
    reqKey = fetchReq.storageRoot.to(NodeKey)
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
    let reqData = SnapSlotQueueItemRef(accHash: fetchReq.accHash)

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
# Public functions, debugging helpers (will go away eventually)
# ------------------------------------------------------------------------------

proc pp*(ctx: SnapCtxRef; bh: BlockHash): string =
  ## Pretty printer for debugging
  let rc = ctx.data.seenBlock.lruFetch(bh.Hash256.to(NodeKey))
  if rc.isOk:
    return "#" & $rc.value
  "%" & $bh.to(Hash256).data.toHex

proc pp*(ctx: SnapCtxRef; bh: BlockHash; bn: BlockNumber): string =
  ## Pretty printer for debugging
  let rc = ctx.data.seenBlock.lruFetch(bh.Hash256.to(NodeKey))
  if rc.isOk:
    return "#" & $rc.value
  "#" & $ctx.data.seenBlock.lruAppend(bh.Hash256.to(NodeKey), bn, seenBlocksMax)

proc pp*(ctx: SnapCtxRef; bhn: HashOrNum): string =
  if not bhn.isHash:
    return "#" & $bhn.number
  let rc = ctx.data.seenBlock.lruFetch(bhn.hash.to(NodeKey))
  if rc.isOk:
    return "%" & $rc.value
  return "%" & $bhn.hash.data.toHex

proc seen*(ctx: SnapCtxRef; bh: BlockHash; bn: BlockNumber) =
  ## Register for pretty printing
  if not ctx.data.seenBlock.lruFetch(bh.Hash256.to(NodeKey)).isOk:
    discard ctx.data.seenBlock.lruAppend(
      bh.Hash256.to(NodeKey), bn, seenBlocksMax)

proc pp*(a: MDigest[256]; collapse = true): string =
  if not collapse:
    a.data.mapIt(it.toHex(2)).join.toLowerAscii
  elif a == EMPTY_ROOT_HASH:
    "EMPTY_ROOT_HASH"
  elif a == EMPTY_UNCLE_HASH:
    "EMPTY_UNCLE_HASH"
  elif a == EMPTY_SHA3:
    "EMPTY_SHA3"
  elif a == ZERO_HASH256:
    "ZERO_HASH256"
  else:
    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

proc pp*(bh: BlockHash): string =
  "%" & bh.Hash256.pp

proc pp*(bn: BlockNumber): string =
  if bn == high(BlockNumber): "#high"
  else: "#" & $bn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
