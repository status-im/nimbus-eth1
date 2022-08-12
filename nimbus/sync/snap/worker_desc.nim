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

  maxPivotBlockWindow* = 500
    ## The maximal depth of two block headers. If the pivot block header
    ## (containing the current state root) is more than this many blocks
    ## away from a new pivot block header candidate, then the latter one
    ## replaces the current block header.

  snapAccountsDumpRangeKiln = (high(UInt256) div 300000)
    ## Sample size for a single snap dump on `kiln` (for debugging)

  snapAccountsDumpRange* = snapAccountsDumpRangeKiln
    ## Activated size of a data slice if dump is anabled

  snapAccountsDumpMax* = 20
    ## Max number of snap proof dumps (for debugging)

  snapAccountsDumpEnable* = false
    ## Enable data dump

  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  WorkerBase* = ref object of RootObj
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

  WorkerTickerBase* = ref object of RootObj
    ## Stub object, to be inherited in file `ticker.nim`

  WorkerFetchBase* = ref object of RootObj
    ## Stub object, to be inherited in file `fetch.nim`

  WorkerFetchEnvBase* = ref object of RootObj
    ## Stub object, to be inherited in file `fetch.nim`

  SnapPivotRef* = ref object
    ## Stub object, cache for particular snap data environment
    stateHeader*: BlockHeader         ## Pivot state, containg state root
    pivotAccount*: NodeTag            ## Random account
    availAccounts*: LeafRangeSet      ## Accounts to fetch (organised as ranges)
    nAccounts*: uint64                ## Number of accounts imported
    # fetchEnv*: WorkerFetchEnvBase     ## Opaque object reference
    # ---
    proofDumpOk*: bool
    proofDumpInx*: int

  SnapPivotTable* = ##\
    ## LRU table, indexed by state root
    KeyedQueue[Hash256,SnapPivotRef]

  BuddyData* = object
    ## Local descriptor data extension
    stats*: SnapBuddyStats            ## Statistics counters
    errors*: SnapBuddyErrors          ## For error handling
    pivotHeader*: Option[BlockHeader] ## For pivot state hunter
    workerBase*: WorkerBase           ## Opaque object reference for sub-module

  CtxData* = object
    ## Globally shared data extension
    seenBlock: WorkerSeenBlocks       ## Temporary, debugging, pretty logs
    rng*: ref HmacDrbgContext         ## Random generator
    dbBackend*: ChainDB               ## Low level DB driver access (if any)
    ticker*: TickerRef                ## Ticker, logger
    pivotTable*: SnapPivotTable       ## Per state root environment
    pivotCount*: uint64               ## Total of all created tab entries
    pivotEnv*: SnapPivotRef           ## Environment containing state root
    accountRangeMax*: UInt256         ## Maximal length, high(u256)/#peers
    accountsDb*: AccountsDbRef        ## Proof processing for accounts
    # ---
    proofDumpOk*: bool
    proofDumpFile*: File

  SnapBuddyRef* = ##\
    ## Extended worker peer descriptor
    BuddyRef[CtxData,BuddyData]

  SnapCtxRef* = ##\
    ## Extended global descriptor
    CtxRef[CtxData]

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
