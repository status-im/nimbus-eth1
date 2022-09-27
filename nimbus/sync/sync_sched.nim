# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Sync worker peers scheduler template
## ====================================
##
## Virtual method/interface functions to be provided as `mixin`:
##
## *runSetup(ctx: CtxRef[S]; tickerOK: bool): bool*
##   Global set up. This function will be called before any worker peer is
##   started. If that function returns `false`, no worker peers will be run.
##
## *runRelease(ctx: CtxRef[S])*
##   Global clean up, done with all the worker peers.
##
##
## *runStart(buddy: BuddyRef[S,W]): bool*
##   Initialise a new worker peer.
##
## *runStop(buddy: BuddyRef[S,W])*
##   Clean up this worker peer.
##
##
## *runPool(buddy: BuddyRef[S,W], last: bool)*
##   Once started, the function `runPool()` is called for all worker peers in
##   sequence as the body of an iteration. There will be no other worker peer
##   functions activated simultaneously.
##
##   This procedure is started if the global flag `buddy.ctx.poolMode` is set
##   `true` (default is `false`.) It is the responsibility of the `runPool()`
##   instance to reset the flag `buddy.ctx.poolMode`, typically at the first
##   peer instance.
##
##   The argument `last` is set `true` if the last entry is reached.
##
##   Note that this function does not run in `async` mode.
##
##
## *runSingle(buddy: BuddyRef[S,W]) {.async.}*
##   This worker peer method is invoked if the peer-local flag
##   `buddy.ctrl.multiOk` is set `false` which is the default mode. This flag
##   is updated by the worker peer when deemed appropriate.
##   * For all workers, there can be only one `runSingle()` function active
##     simultaneously for all worker peers.
##   * There will be no `runMulti()` function active for the same worker peer
##     simultaneously
##   * There will be no `runPool()` iterator active simultaneously.
##
##   Note that this function runs in `async` mode.
##
## *runMulti(buddy: BuddyRef[S,W]) {.async.}*
##   This worker peer method is invoked if the `buddy.ctrl.multiOk` flag is
##   set `true` which is typically done after finishing `runSingle()`. This
##   instance can be simultaneously active for all worker peers.
##
##
## Additional import files needed when using this template:
## * eth/[common/eth_types, p2p]
## * chronicles
## * chronos
## * stew/[interval_set, sorted_set],
## * "."/[sync_desc, sync_sched, protocol]
##

import
  std/hashes,
  chronos,
  eth/[common/eth_types, p2p, p2p/peer_pool, p2p/private/p2p_types],
  stew/keyed_queue,
  ./sync_desc

{.push raises: [Defect].}

type
  ActiveBuddies[S,W] = ##\
    ## List of active workers, using `Hash(Peer)` rather than `Peer`
    KeyedQueue[Hash,RunnerBuddyRef[S,W]]

  RunnerSyncRef*[S,W] = ref object
    ## Module descriptor
    ctx*: CtxRef[S]             ## Shared data
    pool: PeerPool              ## For starting the system
    buddies: ActiveBuddies[S,W] ## LRU cache with worker descriptors
    tickerOk: bool              ## Ticker logger
    singleRunLock: bool         ## For worker initialisation
    monitorLock: bool           ## For worker monitor
    activeMulti: int            ## Activated runners

  RunnerBuddyRef[S,W] = ref object
    ## Per worker peer descriptor
    dsc: RunnerSyncRef[S,W]     ## Scheduler descriptor
    worker: BuddyRef[S,W]       ## Worker peer data

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(peer: Peer): Hash =
  ## Needed for `buddies` table key comparison
  peer.remote.id.hash

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc workerLoop[S,W](buddy: RunnerBuddyRef[S,W]) {.async.} =
  mixin runMulti, runSingle, runPool, runStop
  let
    dsc = buddy.dsc
    ctx = dsc.ctx
    worker = buddy.worker
    peer = worker.peer

  # Continue until stopped
  while not worker.ctrl.stopped:
    if dsc.monitorLock:
      await sleepAsync(50.milliseconds)
      continue

    # Invoke `runPool()` over all buddies if requested
    if ctx.poolMode:
      # Grab `monitorLock` (was `false` as checked above) and wait until clear
      # to run as the only activated instance.
      dsc.monitorLock = true
      block poolModeExec:
        while 0 < dsc.activeMulti:
          await sleepAsync(50.milliseconds)
          if worker.ctrl.stopped:
            break poolModeExec
        while dsc.singleRunLock:
          await sleepAsync(50.milliseconds)
          if worker.ctrl.stopped:
            break poolModeExec
        var count = dsc.buddies.len
        for w in dsc.buddies.nextValues:
          count.dec
          worker.runPool(count == 0)
        # End `block poolModeExec`
      dsc.monitorLock = false
      continue

    # Rotate connection table so the most used entry is at the top/right
    # end. So zombies will end up leftish.
    discard dsc.buddies.lruFetch(peer.hash)

    # Allow task switch
    await sleepAsync(50.milliseconds)
    if worker.ctrl.stopped:
      break

    # Multi mode
    if worker.ctrl.multiOk:
      if not dsc.singleRunLock:
        dsc.activeMulti.inc
        # Continue doing something, work a bit
        await worker.runMulti()
        dsc.activeMulti.dec
      continue

    # Single mode as requested. The `multiOk` flag for this worker was just
    # found `false` in the pervious clause.
    if not dsc.singleRunLock:
      # Lock single instance mode and wait for other workers to finish
      dsc.singleRunLock = true
      block singleModeExec:
        while 0 < dsc.activeMulti:
          await sleepAsync(50.milliseconds)
          if worker.ctrl.stopped:
            break singleModeExec
        # Run single instance and release afterwards
        await worker.runSingle()
        # End `block singleModeExec`
      dsc.singleRunLock = false

    # End while

  # Note that `runStart()` was dispatched in `onPeerConnected()`
  worker.runStop()


proc onPeerConnected[S,W](dsc: RunnerSyncRef[S,W]; peer: Peer) =
  mixin runStart, runStop
  # Check for known entry (which should not exist.)
  let
    maxWorkers = dsc.ctx.buddiesMax
    peers = dsc.pool.len
    workers = dsc.buddies.len
  if dsc.buddies.hasKey(peer.hash):
    trace "Reconnecting zombie peer ignored", peer, peers, workers, maxWorkers
    return

  # Initialise worker for this peer
  let buddy = RunnerBuddyRef[S,W](
    dsc:    dsc,
    worker: BuddyRef[S,W](
      ctx:  dsc.ctx,
      ctrl: BuddyCtrlRef(),
      peer: peer))
  if not buddy.worker.runStart():
    trace "Ignoring useless peer", peer, peers, workers, maxWorkers
    buddy.worker.ctrl.zombie = true
    return

  # Check for table overflow. An overflow might happen if there are zombies
  # in the table (though preventing them from re-connecting for a while.)
  if dsc.ctx.buddiesMax <= workers:
    let leastPeer = dsc.buddies.shift.value.data
    if leastPeer.worker.ctrl.zombie:
      trace "Dequeuing zombie peer",
        oldest=leastPeer.worker, peers, workers=dsc.buddies.len, maxWorkers
      discard
    else:
      # This could happen if there are idle entries in the table, i.e.
      # somehow hanging runners.
      trace "Peer table full! Dequeuing least used entry",
        oldest=leastPeer.worker, peers, workers=dsc.buddies.len, maxWorkers
      leastPeer.worker.runStop()
      leastPeer.worker.ctrl.zombie = true

  # Add peer entry
  discard dsc.buddies.lruAppend(peer.hash, buddy, dsc.ctx.buddiesMax)

  trace "Running peer worker", peer, peers,
    workers=dsc.buddies.len, maxWorkers

  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  let
    peers = dsc.pool.len
    maxWorkers = dsc.ctx.buddiesMax
    workers = dsc.buddies.len
    rc = dsc.buddies.eq(peer.hash)
  if rc.isErr:
    debug "Disconnected, unregistered peer", peer, peers, workers, maxWorkers
    return
  if rc.value.worker.ctrl.zombie:
    # Don't disconnect, leave them fall out of the LRU cache. The effect is,
    # that reconnecting might be blocked, for a while.
    trace "Disconnected, zombie", peer, peers, workers, maxWorkers
  else:
    rc.value.worker.ctrl.stopped = true # in case it is hanging somewhere
    dsc.buddies.del(peer.hash)
    trace "Disconnected buddy", peer, peers, workers=dsc.buddies.len, maxWorkers

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initSync*[S,W](
    dsc: RunnerSyncRef[S,W];
    node: EthereumNode;
    slots: int;
    noisy = false) =
  ## Constructor
  # Leave one extra slot so that it can holds a *zombie* even if all slots
  # are full. The effect is that a re-connect on the latest zombie will be
  # rejected as long as its worker descriptor is registered.
  dsc.ctx = CtxRef[S](
    buddiesMax: max(1, slots + 1),
    chain: node.chain)
  dsc.pool = node.peerPool
  dsc.tickerOk = noisy
  dsc.buddies.init(dsc.ctx.buddiesMax)

proc startSync*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Set up syncing. This call should come early.
  mixin runSetup
  # Initialise sub-systems
  if dsc.ctx.runSetup(dsc.tickerOk):
    var po = PeerObserver(
      onPeerConnected:
        proc(p: Peer) {.gcsafe.} =
          dsc.onPeerConnected(p),
      onPeerDisconnected:
        proc(p: Peer) {.gcsafe.} =
          dsc.onPeerDisconnected(p))

    po.setProtocol eth
    dsc.pool.addObserver(dsc, po)
    return true

proc stopSync*[S,W](dsc: RunnerSyncRef[S,W]) =
  ## Stop syncing
  mixin runRelease
  dsc.pool.delObserver(dsc)
  dsc.ctx.runRelease()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
