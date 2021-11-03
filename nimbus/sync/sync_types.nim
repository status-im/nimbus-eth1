# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Shared types, data structures and shared utilities used by the eth1
## network sync processes.

import
  stint, stew/byteutils, chronicles,
  eth/[common/eth_types, p2p]

const
  tracePackets*         = true
    ## Whether to `trace` log each sync network message.
  traceGossips*         = false
    ## Whether to `trace` log each gossip network message.
  traceHandshakes*      = true
    ## Whether to `trace` log each network handshake message.
  traceTimeouts*        = true
    ## Whether to `trace` log each network request timeout.
  traceNetworkErrors*   = true
    ## Whether to `trace` log each network request error.
  tracePacketErrors*    = true
    ## Whether to `trace` log each messages with invalid data.
  traceIndividualNodes* = false
    ## Whether to `trace` log each trie node, account, storage, receipt, etc.

template tracePacket*(msg: static[string], args: varargs[untyped]) =
  if tracePackets: trace `msg`, `args`
template traceGossip*(msg: static[string], args: varargs[untyped]) =
  if traceGossips: trace `msg`, `args`
template traceTimeout*(msg: static[string], args: varargs[untyped]) =
  if traceTimeouts: trace `msg`, `args`
template traceNetworkError*(msg: static[string], args: varargs[untyped]) =
  if traceNetworkErrors: trace `msg`, `args`
template tracePacketError*(msg: static[string], args: varargs[untyped]) =
  if tracePacketErrors: trace `msg`, `args`

type
  NewSync* = ref object
    ## Shared state among all peers of a syncing node.
    syncPeers*:             seq[SyncPeer]

  SyncPeer* = ref object
    ## Peer state tracking.
    ns*:                    NewSync
    peer*:                  Peer                    # p2pProtocol(eth65).
    stopped*:               bool
    pendingGetBlockHeaders*:bool
    stats*:                 SyncPeerStats

    # Peer canonical chain head ("best block") search state.
    bestBlockHash*:         BlockHash
    bestBlockNumber*:       BlockNumber
    syncMode*:              SyncPeerMode
    huntLow*:               BlockNumber # Recent highest known present block.
    huntHigh*:              BlockNumber # Recent lowest known absent block.
    huntStep*:              typeof(BlocksRequest.skip)

  SyncPeerMode* = enum
    ## The current state of tracking the peer's canonical chain head.
    ## `bestBlockNumber` is only valid when this is `SyncLocked`.
    SyncLocked
    SyncOnlyHash
    SyncHuntForward
    SyncHuntBackward
    SyncHuntRange
    SyncHuntRangeFinal

  SyncPeerStats = object
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok*:                    SyncPeerStatsOk
    minor*:                 SyncPeerStatsMinor
    major*:                 SyncPeerStatsMajor

  SyncPeerStatsOk = object
    reorgDetected*:         Stat
    getBlockHeaders*:       Stat

  SyncPeerStatsMinor = object
    timeoutBlockHeaders*:   Stat
    unexpectedBlockHash*:   Stat

  SyncPeerStatsMajor = object
    networkErrors*:         Stat
    excessBlockHeaders*:    Stat
    wrongBlockHeader*:      Stat

  Stat = distinct int

  BlockHash* = Hash256
    ## Hash of a block, goes with `BlockNumber`.

proc inc(stat: var Stat) {.borrow.}

template `$`*(sp: SyncPeer): string = $sp.peer
template `$`*(hash: Hash256): string = hash.data.toHex
template `$`*(blob: Blob): string = blob.toHex
template `$`*(hashOrNum: HashOrNum): string =
  # It's always obvious which one from the visible length of the string.
  if hashOrNum.isHash: $hashOrNum.hash
  else: $hashOrNum.number

export Blob, Hash256, toHex

# The files and lines clutter more useful details when sync tracing is enabled.
publicLogScope: chroniclesLineNumbers=false
