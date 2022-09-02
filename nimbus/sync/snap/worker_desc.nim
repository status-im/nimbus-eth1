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
  std/[sequtils, strutils],
  eth/[common/eth_types, p2p],
  nimcrypto,
  stew/[byteutils, keyed_queue],
  ../../db/select_backend,
  ../../constants,
  ".."/[sync_desc, types],
  ./worker/[accounts_db, ticker],
  ./range_desc

{.push raises: [Defect].}

const
  snapRequestBytesLimit* = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

  maxPivotBlockWindow* = 50
    ## The maximal depth of two block headers. If the pivot block header
    ## (containing the current state root) is more than this many blocks
    ## away from a new pivot block header candidate, then the latter one
    ## replaces the current block header.
    ##
    ## This mechanism applies to new worker buddies which start by finding
    ## a new pivot.

  switchPivotAfterCoverage* = 1.0 # * 0.30
    ## Stop fetching from the same pivot state root with this much coverage
    ## and try to find a new one. Setting this value to `1.0`, this feature
    ## is disabled. Note that settting low coverage levels is primarily for
    ## testing/debugging (may produce stress conditions.)
    ##
    ## If this setting is active, it typically supersedes the pivot update
    ## mechainsm implied by the `maxPivotBlockWindow`. This for the simple
    ## reason that the pivot state root is typically near the head of the
    ## block chain.
    ##
    ## This mechanism applies to running worker buddies. When triggered, all
    ## pivot handlers are reset so they will start from scratch finding a
    ## better pivot.

  # ---

  snapAccountsDumpEnable* = false # or true
    ## Enable data dump

  snapAccountsDumpCoverageStop* = 0.99999
    ## Stop dumping if most accounts are covered

  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  WorkerPivotBase* = ref object of RootObj
    ## Stub object, to be inherited in file `worker.nim`

  BuddyStat* = distinct uint

  SnapBuddyStats* = tuple
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok: tuple[
      reorgDetected:       BuddyStat,
      getBlockHeaders:     BuddyStat,
      getNodeData:         BuddyStat]
    minor: tuple[
      timeoutBlockHeaders: BuddyStat,
      unexpectedBlockHash: BuddyStat]
    major: tuple[
      networkErrors:       BuddyStat,
      excessBlockHeaders:  BuddyStat,
      wrongBlockHeader:    BuddyStat]

  SnapBuddyErrors* = tuple
    ## particular error counters so connections will not be cut immediately
    ## after a particular error.
    nTimeouts: uint

  # -------

  WorkerSeenBlocks = KeyedQueue[array[32,byte],BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  SnapPivotRef* = ref object
    ## Per-state root cache for particular snap data environment
    stateHeader*: BlockHeader          ## Pivot state, containg state root
    pivotAccount*: NodeTag             ## Random account
    availAccounts*: LeafRangeSet       ## Accounts to fetch (as ranges)
    nAccounts*: uint64                 ## Number of accounts imported
    nStorage*: uint64                  ## Number of storage spaces imported
    leftOver*: seq[AccountSlotsHeader] ## Fetch storage for these accounts
    when switchPivotAfterCoverage < 1.0:
      minCoverageReachedOk*: bool      ## Stop filling this pivot

  SnapPivotTable* = ##\
    ## LRU table, indexed by state root
    KeyedQueue[Hash256,SnapPivotRef]

  BuddyData* = object
    ## Per-worker local descriptor data extension
    stats*: SnapBuddyStats             ## Statistics counters
    errors*: SnapBuddyErrors           ## For error handling
    pivotHeader*: Option[BlockHeader]  ## For pivot state hunter
    workerPivot*: WorkerPivotBase      ## Opaque object reference for sub-module

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
    pivotCount*: uint64                ## Total of all created tab entries
    pivotEnv*: SnapPivotRef            ## Environment containing state root
    accountRangeMax*: UInt256          ## Maximal length, high(u256)/#peers
    accountsDb*: AccountsDbRef         ## Proof processing for accounts
    runPoolHook*: BuddyPoolHookFn      ## Callback for `runPool()`
    # --------
    when snapAccountsDumpEnable:
      proofDumpOk*: bool
      proofDumpFile*: File
      proofDumpInx*: int

  SnapBuddyRef* = BuddyRef[CtxData,BuddyData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[CtxData]
    ## Extended global descriptor

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc inc(stat: var BuddyStat) {.borrow.}

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
  elif a == BLANK_ROOT_HASH:
    "BLANK_ROOT_HASH"
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
