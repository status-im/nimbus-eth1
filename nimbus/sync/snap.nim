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
  eth/p2p/[peer_pool, private/p2p_types, rlpx],
  stint,
  ./protocol,
  ./snap/[base_desc, chain_head_tracker, get_nodedata, types],
  ./snap/pie/[sync_desc, peer_desc]

{.push raises: [Defect].}

type
  SnapSyncCtx* = ref object of SnapSyncEx
    peerPool: PeerPool

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fetchPeerDesc(ns: SnapSyncCtx, peer: Peer): SnapPeerEx =
  ## Find matching peer and remove descriptor from list
  for i in 0 ..< ns.syncPeers.len:
    if ns.syncPeers[i].peer == peer:
      result = ns.syncPeers[i].ex
      ns.syncPeers.delete(i)
      return

proc new(T: type SnapPeerEx; ns: SnapSyncCtx; peer: Peer): T =
  T(
    ns:              ns,
    peer:            peer,
    stopped:         false,
    # Initial state: hunt forward, maximum uncertainty range.
    syncMode:        SyncHuntForward,
    huntLow:         0.toBlockNumber,
    huntHigh:        high(BlockNumber),
    huntStep:        0,
    bestBlockNumber: 0.toBlockNumber)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc syncPeerLoop(sp: SnapPeerEx) {.async.} =
  # This basic loop just runs the head-hunter for each peer.
  while not sp.stopped:
    await sp.peerHuntCanonical()
    if sp.stopped:
      return
    let delayMs = if sp.syncMode == SyncLocked: 1000 else: 50
    await sleepAsync(chronos.milliseconds(delayMs))


proc syncPeerStart(sp: SnapPeerEx) =
  asyncSpawn sp.syncPeerLoop()

proc syncPeerStop(sp: SnapPeerEx) =
  sp.stopped = true
  # TODO: Cancel running `SnapPeerEx` instances.  We need clean cancellation
  # for this.  Doing so reliably will be addressed at a later time.


proc onPeerConnected(ns: SnapSyncCtx, peer: Peer) =
  trace "Snap: Peer connected", peer

  let sp = SnapPeerEx.new(ns, peer)
  sp.setupGetNodeData()

  if peer.state(eth).initialized:
    # We know the hash but not the block number.
    sp.bestBlockHash = peer.state(eth).bestBlockHash.BlockHash
    # TODO: Temporarily disabled because it's useful to test the head hunter.
    # sp.syncMode = SyncOnlyHash
  else:
    trace "Snap: state(eth) not initialized!"

  ns.syncPeers.add(sp)
  sp.syncPeerStart()

proc onPeerDisconnected(ns: SnapSyncCtx, peer: Peer) =
  trace "Snap: Peer disconnected", peer

  let sp = ns.fetchPeerDesc(peer)
  if sp.isNil:
    debug "Snap: Disconnected from unregistered peer", peer
  else:
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
