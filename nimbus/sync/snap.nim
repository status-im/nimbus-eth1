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
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, rlp],
  eth/p2p/[rlpx, peer_pool, private/p2p_types],
  stint,
  "."/[protocol, sync_types],
  ./snap/[chain_head_tracker, get_nodedata]

{.push raises: [Defect].}

type
  SnapSyncCtx* = ref object of SnapSync
    peerPool: PeerPool

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc syncPeerLoop(sp: SyncPeer) {.async.} =
  # This basic loop just runs the head-hunter for each peer.
  while not sp.stopped:
    await sp.peerHuntCanonical()
    if sp.stopped:
      return
    let delayMs = if sp.syncMode == SyncLocked: 1000 else: 50
    await sleepAsync(chronos.milliseconds(delayMs))

proc syncPeerStart(sp: SyncPeer) =
  asyncSpawn sp.syncPeerLoop()

proc syncPeerStop(sp: SyncPeer) =
  sp.stopped = true
  # TODO: Cancel SyncPeers that are running.  We need clean cancellation for
  # this.  Doing so reliably will be addressed at a later time.

proc onPeerConnected(ns: SnapSyncCtx, protocolPeer: Peer) =
  let sp = SyncPeer(
    ns:              ns,
    peer:            protocolPeer,
    stopped:         false,
    # Initial state: hunt forward, maximum uncertainty range.
    syncMode:        SyncHuntForward,
    huntLow:         0.toBlockNumber,
    huntHigh:        high(BlockNumber),
    huntStep:        0,
    bestBlockNumber: 0.toBlockNumber)
  trace "Sync: Peer connected", peer=sp

  sp.setupGetNodeData()

  if protocolPeer.state(eth).initialized:
    # We know the hash but not the block number.
    sp.bestBlockHash = protocolPeer.state(eth).bestBlockHash
    #TODO: Temporarily disabled because it's useful to test the head hunter.
    #sp.syncMode = SyncOnlyHash
  else:
    trace "Sync: state(eth) not initialized!"

  ns.syncPeers.add(sp)
  sp.syncPeerStart()

proc onPeerDisconnected(ns: SnapSyncCtx, protocolPeer: Peer) =
  trace "Sync: Peer disconnected", peer=protocolPeer
  # Find matching `sp` and remove from `ns.syncPeers`.
  var sp: SyncPeer = nil
  for i in 0 ..< ns.syncPeers.len:
    if ns.syncPeers[i].peer == protocolPeer:
      sp = ns.syncPeers[i]
      ns.syncPeers.delete(i)
      break
  if sp.isNil:
    debug "Sync: Unknown peer disconnected", peer=protocolPeer
    return

  sp.syncPeerStop()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc new*(T: type SnapSyncCtx; ethNode: EthereumNode): T =
  ## Constructor
  new result
  result.peerPool = ethNode.peerPool

proc start*(ctx: SnapSyncCtx) =
  ## Set up syncing. This call should come early.
  var po = PeerObserver(
    onPeerConnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerConnected(p),
    onPeerDisconnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerDisconnected(p))
  po.setProtocol eth
  ctx.peerPool.addObserver(ctx, po)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
