# Nimbus - New sync approach - A fusion of snap, trie, beam and other methods
#
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
  stew/[byteutils, keyed_queue],
  "../.."/[constants, db/select_backend],
  ".."/[sync_desc, types],
  ./worker/[com/com_error, snap_db, ticker],
  ./range_desc

{.push raises: [Defect].}

const
  snapRequestBytesLimit* = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

  minPivotBlockDistance* = 128
    ## The minimal depth of two block headers needed to activate a new state
    ## root pivot.

  maxTrieNodeFetch* = 1024
    ## Informal maximal number of trie nodes to fetch at once. This is nor
    ## an official limit but found on several implementations (e.g. geth.)
    ##
    ## Resticting the fetch list length early allows to better paralellise
    ## healing.

  # -------

  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  WorkerSeenBlocks = KeyedQueue[array[32,byte],BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  SnapSlotQueueItemRef* = ref object
    ## Accounts storage request data.
    q*: seq[AccountSlotsHeader]

  SnapSlotsQueue* = KeyedQueueNV[SnapSlotQueueItemRef]
    ## Handles list of storage data for re-fetch.
    ##
    ## This construct is the is a nested queue rather than a flat one because
    ## only the first element of a `seq[AccountSlotsHeader]` queue can have an
    ## effective sub-range specification (later ones will be ignored.)

  SnapSlotsSet* = HashSet[SnapSlotQueueItemRef]
    ## Ditto but without order, to be used as veto set

  SnapRepairState* = enum
    Pristine                           ## Not initialised yet
    KeepGoing                          ## Unfinished repair process
    Done                               ## Stop repairing

  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root
    pivotAccount*: NodeTag             ## Random account
    availAccounts*: LeafRangeSet       ## Accounts to fetch (as ranges)
    nAccounts*: uint64                 ## Number of accounts imported
    nStorage*: uint64                  ## Number of storage spaces imported
    leftOver*: SnapSlotsQueue          ## Re-fetch storage for these accounts
    dangling*: seq[Blob]               ## Missing nodes for healing process
    repairState*: SnapRepairState      ## State of healing process

  SnapPivotTable* = ##\
    ## LRU table, indexed by state root
    KeyedQueue[Hash256,SnapPivotRef]

  BuddyData* = object
    ## Per-worker local descriptor data extension
    errors*: ComErrorStatsRef          ## For error handling
    pivotFinder*: RootRef              ## Opaque object reference for sub-module
    pivotEnv*: SnapPivotRef            ## Environment containing state root
    vetoSlots*: SnapSlotsSet           ## Do not ask for these slots, again

  BuddyPoolHookFn* = proc(buddy: BuddyRef[CtxData,BuddyData]) {.gcsafe.}
    ## All buddies call back (the argument type is defined below with
    ## pretty name `SnapBuddyRef`.)

  CtxData* = object
    ## Globally shared data extension
    seenBlock: WorkerSeenBlocks        ## Temporary, debugging, pretty logs
    rng*: ref HmacDrbgContext          ## Random generator
    coveredAccounts*: LeafRangeSet     ## Derived from all available accounts
    dbBackend*: ChainDB                ## Low level DB driver access (if any)
    ticker*: TickerRef                 ## Ticker, logger
    pivotTable*: SnapPivotTable        ## Per state root environment
    pivotFinderCtx*: RootRef           ## Opaque object reference for sub-module
    accountRangeMax*: UInt256          ## Maximal length, high(u256)/#peers
    snapDb*: SnapDbRef                 ## Accounts snapshot DB
    runPoolHook*: BuddyPoolHookFn      ## Callback for `runPool()`

  SnapBuddyRef* = BuddyRef[CtxData,BuddyData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[CtxData]
    ## Extended global descriptor

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
# Public functions, debugging helpers (will go away eventually)
# ------------------------------------------------------------------------------

proc pp*(ctx: SnapCtxRef; bh: BlockHash): string =
  ## Pretty printer for debugging
  let rc = ctx.data.seenBlock.lruFetch(bh.to(Hash256).data)
  if rc.isOk:
    return "#" & $rc.value
  "%" & $bh.to(Hash256).data.toHex

proc pp*(ctx: SnapCtxRef; bh: BlockHash; bn: BlockNumber): string =
  ## Pretty printer for debugging
  let rc = ctx.data.seenBlock.lruFetch(bh.to(Hash256).data)
  if rc.isOk:
    return "#" & $rc.value
  "#" & $ctx.data.seenBlock.lruAppend(bh.to(Hash256).data, bn, seenBlocksMax)

proc pp*(ctx: SnapCtxRef; bhn: HashOrNum): string =
  if not bhn.isHash:
    return "#" & $bhn.number
  let rc = ctx.data.seenBlock.lruFetch(bhn.hash.data)
  if rc.isOk:
    return "%" & $rc.value
  return "%" & $bhn.hash.data.toHex

proc seen*(ctx: SnapCtxRef; bh: BlockHash; bn: BlockNumber) =
  ## Register for pretty printing
  if not ctx.data.seenBlock.lruFetch(bh.to(Hash256).data).isOk:
    discard ctx.data.seenBlock.lruAppend(bh.to(Hash256).data, bn, seenBlocksMax)

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
