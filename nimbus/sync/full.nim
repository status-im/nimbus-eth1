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
  ./protocol,
  ./full/[full_desc, worker]

{.push raises: [Defect].}

logScope:
  topics = "full-sync"

type
  ActiveBuddies = ##\
    ## List of active workers
    KeyedQueue[Peer,BuddyRef]

  FullSyncRef* = ref object of CtxRef
    pool: PeerPool         ## for starting the system
    buddies: ActiveBuddies ## LRU cache with worker descriptors
    tickerOk: bool         ## Ticker logger
    singleRunLock: bool    ## For worker initialisation
    monitorLock: bool      ## For worker monitor
    activeMulti: int       ## Activated runners

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc nsCtx(buddy: BuddyRef): FullSyncRef =
  buddy.ctx.FullSyncRef

proc hash(peer: Peer): Hash =
  ## Needed for `buddies` table key comparison
  hash(peer.remote.id)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc workerLoop(buddy: BuddyRef) {.async.} =
  let
    ctx = buddy.nsCtx
    peer = buddy.peer
  trace "Starting peer worker", peer,
    peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax

  # Continue until stopped
  while not buddy.ctrl.stopped:
    if ctx.monitorLock:
      await sleepAsync(500.milliseconds)
      continue

    # Rotate connection table so the most used entry is at the top/right
    # end. So zombies will implicitely be pushed left.
    discard ctx.buddies.lruFetch(peer)

    # Invoke `runPool()` over all buddies if requested
    if ctx.poolMode:
      # Grab `monitorLock` (was `false` as checked above) and wait until clear
      # to run as the only activated instance.
      ctx.monitorLock = true
      while 0 < ctx.activeMulti:
        await sleepAsync(500.milliseconds)
      while ctx.singleRunLock:
        await sleepAsync(500.milliseconds)
      trace "Starting pool mode for repair & recovery"
      for w in ctx.buddies.nextValues:
        buddy.runPool()
      trace "Pool mode done"
      ctx.monitorLock = false
      continue

    await sleepAsync(50.milliseconds)

    # Multi mode
    if buddy.ctrl.multiOk:
      if not ctx.singleRunLock:
        ctx.activeMulti.inc
        # Continue doing something, work a bit
        await buddy.runMulti()
        ctx.activeMulti.dec
      continue

    # Single mode as requested. The `multiOk` flag for this worker was just
    # found `false` in the pervious clause.
    if not ctx.singleRunLock:
      # Lock single instance mode and wait for other workers to finish
      ctx.singleRunLock = true
      while 0 < ctx.activeMulti:
        await sleepAsync(500.milliseconds)
      # Run single instance and release afterwards
      await buddy.runSingle()
      ctx.singleRunLock = false

    # End while

  buddy.stop()

  trace "Peer worker done", peer, ctrlState=buddy.ctrl.state,
    peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax


proc onPeerConnected(ctx: FullSyncRef; peer: Peer) =
  # Check for known entry (which should not exist.)
  if ctx.buddies.hasKey(peer):
    trace "Reconnecting zombie peer rejected", peer,
      peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax
    return

  # Initialise worker for this peer
  let buddy = BuddyRef(ctx: ctx, peer: peer)
  if not buddy.start():
    trace "Ignoring useless peer", peer,
      peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax
    buddy.ctrl.zombie = true
    return

  # Check for table overflow. An overflow might happen if there are zombies
  # in the table (though preventing them from re-connecting for a while.)
  if ctx.buddiesMax <= ctx.buddies.len:
    let leastPeer = ctx.buddies.shift.value.data
    if leastPeer.ctrl.zombie:
      trace "Dequeuing zombie peer", leastPeer,
        peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax
      discard
    else:
      # This could happen if there are idle entries in the table, i.e.
      # somehow hanging runners.
      trace "Peer table full! Dequeuing least used entry", leastPeer,
        peers=ctx.pool.len, workers=ctx.buddies.len, maxWorkers=ctx.buddiesMax
      leastPeer.stop()
      leastPeer.ctrl.zombie = true

  # Add peer entry
  discard ctx.buddies.lruAppend(peer, buddy, ctx.buddiesMax)

  # Run worker
  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected(ctx: FullSyncRef, peer: Peer) =
  let
    peers = ctx.pool.len
    maxWorkers = ctx.buddiesMax
    rc = ctx.buddies.eq(peer)
  if rc.isErr:
    debug "Disconnected from unregistered peer", peer, peers,
      workers=ctx.buddies.len, maxWorkers
    return
  if rc.value.ctrl.zombie:
    # Don't disconnect, leave them fall out of the LRU cache. The effect is,
    # that reconnecting might be blocked, for a while.
    trace "Disconnected zombie", peer, peers,
      workers=ctx.buddies.len, maxWorkers
  else:
    rc.value.ctrl.stopped = true # in case it is hanging somewhere
    ctx.buddies.del(peer)
    trace "Disconnected buddy", peer, peers,
      workers=ctx.buddies.len, maxWorkers

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type FullSyncRef;
    ethNode: EthereumNode;
    maxPeers: int;
    enableTicker: bool): T =
  ## Constructor
  # Leave one extra slot so that it can holds a *zombie* even if all slots
  # are full. The effect is that a re-connect on the latest zombie will be
  # rejected as long as its worker descriptor is registered.
  let lruSize = max(1,maxPeers+1)
  result = T(
    buddiesMax: lruSize,
    chain:      ethNode.chain,
    pool:       ethNode.peerPool,
    tickerOk:   enableTicker)
  result.buddies.init(lruSize)

proc start*(ctx: FullSyncRef) =
  ## Set up syncing. This call should come early.
  var po = PeerObserver(
    onPeerConnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerConnected(p),
    onPeerDisconnected:
      proc(p: Peer) {.gcsafe.} =
        ctx.onPeerDisconnected(p))

  # Initialise sub-systems
  doAssert ctx.workerSetup(ctx.tickerOk)
  po.setProtocol eth
  ctx.pool.addObserver(ctx, po)

proc stop*(ctx: FullSyncRef) =
  ## Stop syncing
  ctx.pool.delObserver(ctx)
  ctx.workerRelease()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
