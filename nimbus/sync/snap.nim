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
  std/hashes,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, p2p/peer_pool, p2p/private/p2p_types],
  stew/keyed_queue,
  "."/[protocol, types],
  ./snap/worker

{.push raises: [Defect].}

logScope:
  topics = "snap-sync"

type
  SnapSyncCtx* = ref object of Worker
    buddies: KeyedQueue[Peer,WorkerBuddy] ## LRU cache with worker descriptors
    pool: PeerPool                        ## for starting the system

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nsCtx(sp: WorkerBuddy): SnapSyncCtx =
  sp.ns.SnapSyncCtx

proc hash(peer: Peer): Hash =
  ## Needed for `buddies` table key comparison
  hash(peer.remote.id)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc workerLoop(sp: WorkerBuddy) {.async.} =
  let ns = sp.nsCtx
  trace "Starting peer worker", peer=sp,
    peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax

  # Do something, work a bit
  await sp.workerExec

  # Continue until stopped
  while not sp.ctrl.stopped:
    # Rotate connection table so the most used entry is at the end
    discard sp.nsCtx.buddies.lruFetch(sp.peer)

    let delayMs = if sp.workerLockedOk: 1000 else: 50
    await sleepAsync(chronos.milliseconds(delayMs))

    # Do something, work a bit
    await sp.workerExec

  trace "Peer worker done", peer=sp, ctrlState=sp.ctrl.state,
    peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax


proc onPeerConnected(ns: SnapSyncCtx, peer: Peer) =
  let sp = WorkerBuddy.new(ns, peer)

  # Check for known entry (which should not exist.)
  if ns.buddies.hasKey(peer):
    trace "Ignoring already registered peer!", peer,
      peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
    return

  # Initialise worker for this peer
  if not sp.workerStart():
    trace "Ignoring useless peer", peer,
      peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
    sp.ctrl.zombie = true
    return

  # Check for table overflow. An overflow should not happen if the table is
  # as large as the peer connection table.
  if ns.buddiesMax <= ns.buddies.len:
    let leastPeer = ns.buddies.shift.value.data
    if leastPeer.ctrl.zombie:
      trace "Dequeuing zombie peer", leastPeer,
        peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
      discard
    else:
      trace "Peer table full! Dequeuing least used entry", leastPeer,
        peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
      leastPeer.workerStop()
      leastPeer.ctrl.zombie = true

  # Add peer entry
  discard ns.buddies.lruAppend(sp.peer, sp, ns.buddiesMax)

  # Run worker
  asyncSpawn sp.workerLoop()


proc onPeerDisconnected(ns: SnapSyncCtx, peer: Peer) =
  let rc = ns.buddies.eq(peer)
  if rc.isErr:
    debug "Disconnected from unregistered peer", peer,
      peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
    return
  let sp = rc.value
  if sp.ctrl.zombie:
    trace "Disconnected zombie peer", peer,
      peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax
  else:
    sp.workerStop()
    ns.buddies.del(peer)
    trace "Disconnected peer", peer,
      peers=ns.pool.len, workers=ns.buddies.len, maxWorkers=ns.buddiesMax

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc new*(T: type SnapSyncCtx; ethNode: EthereumNode; maxPeers: int): T =
  ## Constructor
  new result
  let size = max(1,maxPeers)
  result.buddies.init(size)
  result.buddiesMax = size
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
