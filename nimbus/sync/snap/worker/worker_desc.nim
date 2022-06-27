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
  nimcrypto/hash,
  stew/[byteutils, keyed_queue],
  ../../../constants,
  ../../types

{.push raises: [Defect].}

const
  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  WorkerBase* = ref object of RootObj
    ## Stub object, to be inherited in file `worker.nim`

  BuddyStat* = distinct uint

  BuddyRunState = enum
    ## Combined state of two boolean values (`stopped`,`stopThisState`) as used
    ## in the original source set up (should be double checked and simplified.)
    Running    ## running, not requested to stop
    Stopped    ## stopped, stop request
    ZombieStop ## abanon/ignore (LRU tab overflow, odd packets)
    ZombieRun  ## additional zombie state to potentially recover from

  WorkerBuddyStats* = tuple
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

  WorkerBuddyCtrl* = object
    ## Control and state settings
    stateRoot*:            Option[TrieHash]
      ## State root to fetch state for. This changes during sync and is
      ## slightly different for each peer.
    runState:              BuddyRunState
      ## Access with getters

  # -------

  WorkerSeenBlocks = KeyedQueue[array[32,byte],BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  WorkerTickerBase* = ref object of RootObj
    ## Stub object, to be inherited in file `ticker.nim`

  WorkerFetchBase* = ref object of RootObj
    ## Stub object, to be inherited in file `fetch.nim`

  # -------

  WorkerBuddy* = ref object
    ## Non-inheritable peer state tracking descriptor.
    ns*: Worker                      ## Worker descriptor object back reference
    peer*: Peer                      ## Reference to eth p2pProtocol entry
    stats*: WorkerBuddyStats         ## Statistics counters
    ctrl*: WorkerBuddyCtrl           ## Control and state settings

    workerBase*: WorkerBase          ## Opaque object reference for sub-module
    # ...

  Worker* = ref object of RootObj
    ## Shared state among all peers of a snap syncing node. Will be
    ## amended/inherited into `SnapSyncCtx` by the `snap` module which
    ## will also manage a list of `WorkerBuddy` objects.
    seenBlock: WorkerSeenBlocks      ## Temporary, debugging, pretty logs

    buddiesMax*: int                 ## Max number of buddies (for LRU caches)

    fetchBase*: WorkerFetchBase      ## Opaque object reference
    tickerBase*: WorkerTickerBase    ## Opaque object reference

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc new*(T: type WorkerBuddy; ns: Worker; peer: Peer): T =
  ## Initial state all default settings.
  T(ns: ns, peer: peer)

proc init*(ctrl: var WorkerBuddyCtrl; running: bool) =
  ## Set initial running state `Running` if the argument `running`
  ## is `true`.  Otherwise the running state is set `stopped`.
  ctrl.runState = if running: Running else: Stopped

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(sp: WorkerBuddy): string =
  $sp.peer

proc inc(stat: var BuddyStat) {.borrow.}

# ------------------------------------------------------------------------------
# Public getters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc state*(ctrl: WorkerBuddyCtrl): BuddyRunState =
  ## Getter (logging only, details of `BuddyRunState` are private)
  ctrl.runState

proc running*(ctrl: WorkerBuddyCtrl): bool =
  ## Getter, if `true` if `ctrl.state()` is `Running`
  ctrl.runState == Running

proc stopped*(ctrl: WorkerBuddyCtrl): bool =
  ## Getter, if `true`, if `ctrl.state()` is not `Running`
  ctrl.runState in {Stopped, ZombieStop, ZombieRun}

proc zombie*(ctrl: WorkerBuddyCtrl): bool =
  ## Getter, `true` if `ctrl.state()` is `Zombie` (i.e. not `running()` and
  ## not `stopped()`)
  ctrl.runState in {ZombieStop, ZombieRun}

# ------------------------------------------------------------------------------
# Public setters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc `zombie=`*(ctrl: var WorkerBuddyCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = ZombieRun
    of Stopped:
      ctrl.runState = ZombieStop
    else:
      discard
  else:
    case ctrl.runState:
    of ZombieRun:
      ctrl.runState = Running
    of ZombieStop:
      ctrl.runState = Stopped
    else:
      discard

proc `stopped=`*(ctrl: var WorkerBuddyCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = Stopped
    else:
      discard
  else:
    case ctrl.runState:
    of Stopped:
      ctrl.runState = Running
    else:
      discard

# ------------------------------------------------------------------------------
# Public functions, debugging helpers (will go away eventually)
# ------------------------------------------------------------------------------

proc pp*(sn: Worker; bh: BlockHash): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.to(Hash256).data)
  if rc.isOk:
    return "#" & $rc.value
  $bh.to(Hash256).data.toHex

proc pp*(sn: Worker; bh: BlockHash; bn: BlockNumber): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.to(Hash256).data)
  if rc.isOk:
    return "#" & $rc.value
  "#" & $sn.seenBlock.lruAppend(bh.to(Hash256).data, bn, seenBlocksMax)

proc pp*(sn: Worker; bhn: HashOrNum): string =
  if not bhn.isHash:
    return "num(#" & $bhn.number & ")"
  let rc = sn.seenBlock.lruFetch(bhn.hash.data)
  if rc.isOk:
    return "hash(#" & $rc.value & ")"
  return "hash(" & $bhn.hash.data.toHex & ")"

proc seen*(sn: Worker; bh: BlockHash; bn: BlockNumber) =
  ## Register for pretty printing
  if not sn.seenBlock.lruFetch(bh.to(Hash256).data).isOk:
    discard sn.seenBlock.lruAppend(bh.to(Hash256).data, bn, seenBlocksMax)

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
  bh.Hash256.pp

proc pp*(bn: BlockNumber): string =
  if bn == high(BlockNumber): "#max"
  else: "#" & $bn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
