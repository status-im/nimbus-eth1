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
  ./snap/[base_desc, collect, peer/sync_xdesc]

{.push raises: [Defect].}

logScope:
  topics = "snap sync"

type
  SnapSyncCtx* = ref object of SnapSyncEx
    peerTab: KeyedQueue[Peer,SnapPeer] ## LRU cache
    tabSize: int                       ## maximal number of entries
    pool: PeerPool                     ## for starting the system, debugging

    # debugging
    lastDump: seq[string]
    lastlen: int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nsCtx(sp: SnapPeer): SnapSyncCtx =
  sp.ns.SnapSyncCtx

proc hash(peer: Peer): Hash =
  ## Needed for `peerTab` table key comparison
  hash(peer.remote.id)

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc dumpPeers(sn: SnapSyncCtx; force = false) =
  if sn.lastLen != sn.peerTab.len or force:
    sn.lastLen = sn.peerTab.len

    let poolSize = sn.pool.len
    if sn.peerTab.len == 0:
      trace "*** Empty peer list", poolSize
    else:
      var n = sn.peerTab.len - 1
      for sp in sn.peerTab.prevValues:
        trace "*** Peer list entry",
          n, poolSize, peer=sp, hunt=sp.hunt.pp
        n.dec

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc syncPeerLoop(sp: SnapPeer) {.async.} =
  # This basic loop just runs the head-hunter for each peer.
  var cache = ""
  while sp.ctrl.runState != SyncStopped:

    # Do something, work a bit
    await sp.collectBlockHeaders()
    if sp.ctrl.runState == SyncStopped:
      trace "Ignoring stopped peer", peer=sp
      return

    # Rotate LRU connection table so the most used entry is at the list end
    # TODO: Update implementation of lruFetch() using re-link, only
    discard sp.nsCtx.peerTab.lruFetch(sp.peer)

    let delayMs = if sp.hunt.syncMode == SyncLocked: 1000 else: 50
    await sleepAsync(chronos.milliseconds(delayMs))


proc syncPeerStart(sp: SnapPeer) =
  asyncSpawn sp.syncPeerLoop()

proc syncPeerStop(sp: SnapPeer) =
  sp.ctrl.runState = SyncStopped
  # TODO: Cancel running `SnapPeer` instances.  We need clean cancellation
  # for this.  Doing so reliably will be addressed at a later time.


proc onPeerConnected(ns: SnapSyncCtx, peer: Peer) =
  trace "Peer connected", peer

  let sp = SnapPeer.new(ns, peer, SyncHuntForward, SyncRunningOk)
  sp.collectDataSetup()

  if peer.state(eth).initialized:
    # We know the hash but not the block number.
    sp.hunt.bestHash = peer.state(eth).bestBlockHash.BlockHash
    # TODO: Temporarily disabled because it's useful to test the head hunter.
    # sp.syncMode = SyncOnlyHash
  else:
    trace "State(eth) not initialized!"

  # Manage connection table, check for existing entry
  if ns.peerTab.hasKey(peer):
    trace "Peer exists already!", peer
    return

  # Check for table overflow. An overflow should not happen if the table is
  # as large as the peer connection table.
  if ns.tabSize <= ns.peerTab.len:
    let leastPeer = ns.peerTab.shift.value.data
    leastPeer.syncPeerStop
    trace "Peer table full, deleted least used",
      leastPeer, poolSize=ns.pool.len, tabLen=ns.peerTab.len, tabMax=ns.tabSize

  # Add peer entry
  discard ns.peerTab.append(sp.peer,sp)
  trace "Starting peer",
    peer, poolSize=ns.pool.len, tabLen=ns.peerTab.len, tabMax=ns.tabSize

  # Debugging, peer table dump after adding gentry
  #ns.dumpPeers(true)
  sp.syncPeerStart()

proc onPeerDisconnected(ns: SnapSyncCtx, peer: Peer) =
  trace "Peer disconnected", peer

  # Debugging, peer table dump before removing entry
  #ns.dumpPeers(true)

  let rc = ns.peerTab.delete(peer)
  if rc.isOk:
    rc.value.data.syncPeerStop()
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
  po.setProtocol eth
  ctx.pool.addObserver(ctx, po)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
