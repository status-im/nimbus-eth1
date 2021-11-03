# Nimbus - New sync approach - A fusion of snap, trie, beam and other methods
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  chronos, stint, chronicles, stew/byteutils,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils, peer_pool],
  "."/[sync_types, protocol_eth65, chain_head_tracker]

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
  trace "Sync: Peer disconnected", peer=sp
  sp.stopped = true
  # TODO: Cancel SyncPeers that are running.  We need clean cancellation for
  # this.  Doing so reliably will be addressed at a later time.

proc onPeerConnected(ns: NewSync, protocolPeer: Peer) =
  let sp = SyncPeer(
    ns:              ns,
    peer:            protocolPeer,
    stopped:         false,
    # Initial state: hunt forward, maximum uncertainty range.
    syncMode:        SyncHuntForward,
    huntLow:         0.toBlockNumber,
    huntHigh:        high(BlockNumber),
    huntStep:        0,
    bestBlockNumber: 0.toBlockNumber
  )
  trace "Sync: Peer connected", peer=sp

  if protocolPeer.state(eth).initialized:
    # We know the hash but not the block number.
    sp.bestBlockHash = protocolPeer.state(eth).bestBlockHash
    #TODO: Temporarily disabled because it's useful to test the head hunter.
    #sp.syncMode = SyncOnlyHash
  else:
    trace "Sync: state(eth) not initialized!"

  ns.syncPeers.add(sp)
  sp.syncPeerStart()

proc onPeerDisconnected(ns: NewSync, protocolPeer: Peer) =
  trace "Sync: Peer disconnected", peer=protocolPeer

  var sp: SyncPeer = nil
  for i in 0 ..< ns.syncPeers.len:
    if $ns.syncPeers[i].peer.remote == $sp.peer.remote:
      sp = ns.syncPeers[i]
      ns.syncPeers.delete(i)
      break
  if not sp.isNil:
    sp.syncPeerStop()

proc newSyncEarly*(ethNode: EthereumNode) =
  let ns = NewSync()
  var po = PeerObserver(
    onPeerConnected:
      proc(protocolPeer: Peer) {.gcsafe.} =
        ns.onPeerConnected(protocolPeer),
    onPeerDisconnected:
      proc(protocolPeer: Peer) {.gcsafe.} =
        ns.onPeerDisconnected(protocolPeer)
  )
  po.setProtocol(eth)
  ethNode.peerPool.addObserver(ns, po)

proc newSync*() =
  discard
