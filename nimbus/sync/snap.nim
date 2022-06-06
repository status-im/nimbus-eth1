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
  std/[hashes, strutils],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, p2p/peer_pool, p2p/private/p2p_types],
  stew/keyed_queue,
  "."/[protocol, types],
  ./snap/worker

{.push raises: [Defect].}

logScope:
  topics = "snap sync"

type
  SnapSyncCtx* = ref object of Worker
    peerTab: KeyedQueue[Peer,WorkerBuddy] ## LRU cache
    tabSize: int                          ## maximal number of entries
    pool: PeerPool                        ## for starting the system, debugging

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nsCtx(sp: WorkerBuddy): SnapSyncCtx =
  sp.ns.SnapSyncCtx

proc hash(peer: Peer): Hash =
  ## Needed for `peerTab` table key comparison
  hash(peer.remote.id)

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc dumpPeers(sn: SnapSyncCtx) =
  let poolSize = sn.pool.len
  if sn.peerTab.len == 0:
    trace "*** Empty peer list", poolSize
  else:
    var n = sn.peerTab.len - 1
    for sp in sn.peerTab.prevValues:
      trace "*** Peer list entry", n, poolSize, peer=sp, worker=sp.huntPp
      n.dec

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc syncPeerLoop(sp: WorkerBuddy) {.async.} =
  # This basic loop just runs the head-hunter for each peer.
  var cache = ""
  while not sp.ctrl.stopped:

    # Do something, work a bit
    await sp.workerExec
    if sp.ctrl.stopped:
      trace "Ignoring stopped peer", peer=sp
      return

    # Rotate LRU connection table so the most used entry is at the list end
    # TODO: Update implementation of lruFetch() using re-link, only
    discard sp.nsCtx.peerTab.lruFetch(sp.peer)

    let delayMs = if sp.workerLockedOk: 1000 else: 50
    await sleepAsync(chronos.milliseconds(delayMs))

proc onPeerConnected(ns: SnapSyncCtx, peer: Peer) =
  let
    ethOk = peer.supports(protocol.eth)
    snapOk = peer.supports(protocol.snap)
  trace "Peer connected", peer, ethOk, snapOk

  let sp = WorkerBuddy.new(ns, peer)

  # Manage connection table, check for existing entry
  if ns.peerTab.hasKey(peer):
    trace "Peer exists already!", peer # can this happen, at all?
    return

  # Initialise snap sync for this peer
  if not sp.workerStart():
    trace "State(eth) not initialized!"
    return

  # Check for table overflow. An overflow should not happen if the table is
  # as large as the peer connection table.
  if ns.tabSize <= ns.peerTab.len:
    let leastPeer = ns.peerTab.shift.value.data
    leastPeer.workerStop()
    trace "Peer table full, deleted least used",
      leastPeer, poolSize=ns.pool.len, tabLen=ns.peerTab.len, tabMax=ns.tabSize

  # Add peer entry
  discard ns.peerTab.append(sp.peer,sp)
  trace "Starting peer",
    peer, poolSize=ns.pool.len, tabLen=ns.peerTab.len, tabMax=ns.tabSize

  # Debugging, peer table dump after adding gentry
  #ns.dumpPeers
  asyncSpawn sp.syncPeerLoop()

proc onPeerDisconnected(ns: SnapSyncCtx, peer: Peer) =
  trace "Peer disconnected", peer
  echo "onPeerDisconnected peer=", peer

  # Debugging, peer table dump before removing entry
  #ns.dumpPeers

  let rc = ns.peerTab.delete(peer)
  if rc.isOk:
    rc.value.data.workerStop()
  else:
    debug "Disconnected from unregistered peer", peer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc new*(T: type SnapSyncCtx; ethNode: EthereumNode; maxPeers: int): T =
  ## Constructor
  new result
  let size = max(1,2*maxPeers) # allow double argument size
  result.peerTab.init(size)
  result.tabSize = size
  result.pool = ethNode.peerPool

proc start*(ctx: SnapSyncCtx) =
  ## Set up syncing. This call should come early.
  var po = PeerObserver(
    onPeerConnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerConnected(p),
    onPeerDisconnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerDisconnected(p))

  # Initialise sub-systems
  ctx.workerSetup()
  po.setProtocol eth
  ctx.pool.addObserver(ctx, po)

proc stop*(ctx: SnapSyncCtx) =
  ## Stop syncing
  ctx.pool.delObserver(ctx)
  ctx.workerRelease()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
