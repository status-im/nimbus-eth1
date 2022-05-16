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
  ./types

{.push raises: [Defect].}

type
  SnapStat* = distinct int

  SnapPeerStatsOk = object
    reorgDetected*:         SnapStat
    getBlockHeaders*:       SnapStat
    getNodeData*:           SnapStat

  SnapPeerStatsMinor = object
    timeoutBlockHeaders*:   SnapStat
    unexpectedBlockHash*:   SnapStat

  SnapPeerStatsMajor = object
    networkErrors*:         SnapStat
    excessBlockHeaders*:    SnapStat
    wrongBlockHeader*:      SnapStat

  SnapPeerStats* = object
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok*:                    SnapPeerStatsOk
    minor*:                 SnapPeerStatsMinor
    major*:                 SnapPeerStatsMajor

  SnapPeerMode* = enum
    ## The current state of tracking the peer's canonical chain head.
    ## `bestBlockNumber` is only valid when this is `SyncLocked`.
    SyncLocked
    SyncOnlyHash
    SyncHuntForward
    SyncHuntBackward
    SyncHuntRange
    SyncHuntRangeFinal

  SnapPeerBase* = ref object of RootObj
    ## Peer state tracking.
    ns*:                    SnapSyncBase  ## Opaque object reference
    peer*:                  Peer          ## eth p2pProtocol
    stopped*:               bool
    pendingGetBlockHeaders*:bool
    stats*:                 SnapPeerStats

    # Peer canonical chain head ("best block") search state.
    syncMode*:              SnapPeerMode
    bestBlockNumber*:       BlockNumber
    bestBlockHash*:         BlockHash
    huntLow*:               BlockNumber   ## Recent highest known present block.
    huntHigh*:              BlockNumber   ## Recent lowest known absent block.
    huntStep*:              typeof(BlocksRequest.skip) # aka uint

    # State root to fetch state for.
    # This changes during sync and is slightly different for each peer.
    syncStateRoot*:         Option[TrieHash]
    startedFetch*:          bool
    stopThisState*:         bool

  SnapSyncBase* = ref object of RootObj
    ## Shared state among all peers of a snap syncing node.
    syncPeers*: seq[SnapPeerBase]
      ## Peer state tracking

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*(sp: SnapPeerBase): string =
  $sp.peer

proc inc(stat: var SnapStat) {.borrow.}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
