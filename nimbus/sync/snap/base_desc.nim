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
  eth/[common/eth_types, p2p],
  stew/[byteutils, keyed_queue, results],
  ../../constants,
  ../types

{.push raises: [Defect].}

const
  seenBlocksMax = 500
    ## Internal size of LRU cache (for debugging)

type
  SnapPeerStat* = distinct uint

  SnapPeerFetchBase* = ref object of RootObj
    ## Stub object, to be inherited

  SnapPeerRequestsBase* = ref object of RootObj
    ## Stub object, to be inherited

  SnapPeerMode* = enum
    ## The current state of tracking the peer's canonical chain head.
    ## `bestBlockNumber` is only valid when this is `SyncLocked`.
    SyncLocked
    SyncOnlyHash
    SyncHuntForward
    SyncHuntBackward
    SyncHuntRange
    SyncHuntRangeFinal

  SnapPeerRunState* = enum
    SyncRunningOk
    SyncStopRequest
    SyncStopped

  SnapPeerStats* = tuple
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok: tuple[
      reorgDetected:       SnapPeerStat,
      getBlockHeaders:     SnapPeerStat,
      getNodeData:         SnapPeerStat]
    minor: tuple[
      timeoutBlockHeaders: SnapPeerStat,
      unexpectedBlockHash: SnapPeerStat]
    major: tuple[
      networkErrors:       SnapPeerStat,
      excessBlockHeaders:  SnapPeerStat,
      wrongBlockHeader:    SnapPeerStat]

  SnapPeerHunt* = tuple
    ## Peer canonical chain head ("best block") search state.
    syncMode:              SnapPeerMode   ## Action mode
    lowNumber:             BlockNumber    ## Recent lowest known block number.
    highNumber:            BlockNumber    ## Recent highest known block number.
    bestNumber:            BlockNumber
    bestHash:              BlockHash
    step:                  uint

  SnapPeerCtrl* = tuple
    ## Control and state settings
    stateRoot:             Option[TrieHash]
      ## State root to fetch state for. This changes during sync and is
      ## slightly different for each peer.
    runState:              SnapPeerRunState

  # -------

  SnapSyncSeenBlocks = KeyedQueue[array[32,byte],BlockNumber]
    ## Temporary for pretty debugging, `BlockHash` keyed lru cache

  SnapSyncFetchBase* = ref object of RootObj
    ## Stub object, to be inherited

  # -------

  SnapPeer* = ref object
    ## Non-inheritable peer state tracking descriptor.
    ns*: SnapSync                   ## Snap descriptor object back reference
    peer*: Peer                     ## Reference to eth p2pProtocol entry
    stats*: SnapPeerStats           ## Statistics counters
    hunt*: SnapPeerHunt             ## Peer chain head search state
    ctrl*: SnapPeerCtrl             ## Control and state settings
    requests*: SnapPeerRequestsBase ## Opaque object reference
    fetchState*: SnapPeerFetchBase  ## Opaque object reference

  SnapSync* = ref object of RootObj
    ## Shared state among all peers of a snap syncing node. Will be
    ## amended/inherited into `SnapSyncCtx` by the `snap` module.
    seenBlock: SnapSyncSeenBlocks   ## Temporary, debugging, prettyfied logs
    sharedFetch*: SnapSyncFetchBase ## Opaque object reference

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc new*(
    T: type SnapPeer;
    ns: SnapSync;
    peer: Peer;
    syncMode: SnapPeerMode;
    runState: SnapPeerRunState): T =
  ## Initial state, maximum uncertainty range.
  T(ns:           ns,
    peer:         peer,
    ctrl: (
      stateRoot:  none(TrieHash),
      runState:   runState),
    hunt: (
      syncMode:   syncMode,
      lowNumber:  0.toBlockNumber.BlockNumber,
      highNumber: high(BlockNumber).BlockNumber, # maximum uncertainty range.
      bestNumber: 0.toBlockNumber.BlockNumber,
      bestHash:   ZERO_HASH256.BlockHash,        # whatever
      step:       0u))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(sp: SnapPeer): string =
  $sp.peer

proc inc(stat: var SnapPeerStat) {.borrow.}

# ------------------------------------------------------------------------------
# Public functions, debugging helpers (will go away eventually)
# ------------------------------------------------------------------------------

proc pp*(sn: SnapSync; bh: BlockHash): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.untie.data)
  if rc.isOk:
    return "#" & $rc.value
  $bh.untie.data.toHex

proc pp*(sn: SnapSync; bh: BlockHash; bn: BlockNumber): string =
  ## Pretty printer for debugging
  let rc = sn.seenBlock.lruFetch(bh.untie.data)
  if rc.isOk:
    return "#" & $rc.value
  "#" & $sn.seenBlock.lruAppend(bh.untie.data, bn, seenBlocksMax)

proc pp*(sn: SnapSync; bhn: HashOrNum): string =
  if not bhn.isHash:
    return "num(#" & $bhn.number & ")"
  let rc = sn.seenBlock.lruFetch(bhn.hash.data)
  if rc.isOk:
    return "hash(#" & $rc.value & ")"
  return "hash(" & $bhn.hash.data.toHex & ")"

proc seen*(sn: SnapSync; bh: BlockHash; bn: BlockNumber) =
  ## Register for pretty printing
  if not sn.seenBlock.lruFetch(bh.untie.data).isOk:
    discard sn.seenBlock.lruAppend(bh.untie.data, bn, seenBlocksMax)

# -----------

import
  ../../../tests/replay/pp_light

proc pp*(bh: BlockHash): string =
  bh.Hash256.pp

proc pp*(bn: BlockNumber): string =
  if bn == high(BlockNumber): "#max"
  else: "#" & $bn

proc pp*(sp: SnapPeerHunt): string =
  result &= "(mode=" & $sp.syncMode
  result &= ",num=(" & sp.lowNumber.pp & "," & sp.highNumber.pp & ")"
  result &= ",best=(" & sp.bestNumber.pp & "," & sp.bestHash.pp & ")"
  result &= ",step=" & $sp.step
  result &= ")"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
