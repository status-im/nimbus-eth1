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
##   Also, this function should decide whether the `runDaemon()` job will be
##   started next by controlling the `ctx.daemon` flag (default is `false`.)
##
## *runRelease(ctx: CtxRef[S])*
##   Global clean up, done with all the worker peers.
##
## *runDaemon(ctx: CtxRef[S]) {.async.}*
##   Global background job that will be re-started as long as the variable
##   `ctx.daemon` is set `true`. If that job was stopped due to re-setting
##   `ctx.daemon` to `false`, it will be restarted next after it was reset
##   as `true` not before there is some activity on the `runPool()`,
##   `runSingle()`, or `runMulti()` functions.
##
##
## *runStart(buddy: BuddyRef[S,W]): bool*
##   Initialise a new worker peer.
##
## *runStop(buddy: BuddyRef[S,W])*
##   Clean up this worker peer.
##
##
## *runPool(buddy: BuddyRef[S,W], last: bool): bool*
##   Once started, the function `runPool()` is called for all worker peers in
##   sequence as the body of an iteration as long as the function returns
##   `false`. There will be no other worker peer functions activated
##   simultaneously.
##
##   This procedure is started if the global flag `buddy.ctx.poolMode` is set
##   `true` (default is `false`.) It is the responsibility of the `runPool()`
##   instance to reset the flag `buddy.ctx.poolMode`, typically at the first
##   peer instance.
##
##   The argument `last` is set `true` if the last entry is reached.
##
##   Note:
##   + This function does *not* runs in `async` mode.
##   + The flag `buddy.ctx.poolMode` has priority over the flag
##     `buddy.ctrl.multiOk` which controls `runSingle()` and `runMulti()`.
##
##
## *runSingle(buddy: BuddyRef[S,W]) {.async.}*
##   This worker peer method is invoked if the peer-local flag
##   `buddy.ctrl.multiOk` is set `false` which is the default mode. This flag
##   is updated by the worker peer when deemed appropriate.
##   + For all worker peerss, there can be only one `runSingle()` function
##     active simultaneously.
##   + There will be no `runMulti()` function active for the very same worker
##     peer that runs the `runSingle()` function.
##   + There will be no `runPool()` iterator active.
##
##   Note that this function runs in `async` mode.
##
##
## *runMulti(buddy: BuddyRef[S,W]) {.async.}*
##   This worker peer method is invoked if the `buddy.ctrl.multiOk` flag is
##   set `true` which is typically done after finishing `runSingle()`. This
##   instance can be simultaneously active for all worker peers.
##
##   Note that this function runs in `async` mode.
##
##
## Additional import files needed when using this template:
## * eth/[common, p2p]
## * chronicles
## * chronos
## * stew/[interval_set, sorted_set],
## * "."/[sync_desc, sync_sched, protocol]
##

import
  std/hashes,
  chronos,
  eth/[common, p2p, p2p/peer_pool, p2p/private/p2p_types],
  stew/keyed_queue,
  "."/[handlers, sync_desc]

{.push raises: [Defect].}

static:
  # type `EthWireRef` is needed in `initSync()`
  type silenceUnusedhandlerComplaint = EthWireRef # dummy directive

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
    daemonRunning: bool         ## Run global background job
    singleRunLock: bool         ## Some single mode runner is activated
    monitorLock: bool           ## Monitor mode is activated
    activeMulti: int            ## Number of activated runners in multi-mode
    shutdown: bool              ## Internal shut down flag

  RunnerBuddyRef[S,W] = ref object
    ## Per worker peer descriptor
    dsc: RunnerSyncRef[S,W]     ## Scheduler descriptor
    worker: BuddyRef[S,W]       ## Worker peer data

const
  execLoopTimeElapsedMin = 50.milliseconds
    ## Minimum elapsed time an exec loop needs for a single lap. If it is
    ## faster, asynchroneous sleep seconds are added. in order to avoid
    ## cpu overload.

  execLoopTaskSwitcher = 1.nanoseconds
    ## Asynchroneous waiting time at the end of an exec loop unless some sleep
    ## seconds were added as decribed by `execLoopTimeElapsedMin`, above.

  execLoopPollingTime = 50.milliseconds
    ## Single asynchroneous time interval wait state for event polling

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(peer: Peer): Hash =
  ## Needed for `buddies` table key comparison
  peer.remote.id.hash

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc daemonLoop[S,W](dsc: RunnerSyncRef[S,W]) {.async.} =
  mixin runDaemon

  if dsc.ctx.daemon and not dsc.shutdown:
    dsc.daemonRunning = true

    # Continue until stopped
    while true:
      # Enforce minimum time spend on this loop
      let startMoment = Moment.now()

      await dsc.ctx.runDaemon()

      if not dsc.ctx.daemon:
        break

      # Enforce minimum time spend on this loop so we never each 100% cpu load
      # caused by some empty sub-tasks which are out of this scheduler control.
      let
        elapsed = Moment.now() - startMoment
        suspend = if execLoopTimeElapsedMin <= elapsed: execLoopTaskSwitcher
                  else: execLoopTimeElapsedMin - elapsed
      await sleepAsync suspend
      # End while

  dsc.daemonRunning = false


proc workerLoop[S,W](buddy: RunnerBuddyRef[S,W]) {.async.} =
  mixin runMulti, runSingle, runPool, runStop
  let
    dsc = buddy.dsc
    ctx = dsc.ctx
    worker = buddy.worker
    peer = worker.peer

  # Continue until stopped
  block taskExecLoop:
    while worker.ctrl.running and not dsc.shutdown:
      # Enforce minimum time spend on this loop
      let startMoment = Moment.now()

      if dsc.monitorLock:
        discard # suspend some time at the end of loop body

      # Invoke `runPool()` over all buddies if requested
      elif ctx.poolMode:
        # Grab `monitorLock` (was `false` as checked above) and wait until
        # clear to run as the only activated instance.
        dsc.monitorLock = true
        while 0 < dsc.activeMulti or dsc.singleRunLock:
          await sleepAsync execLoopPollingTime
          if worker.ctrl.stopped:
            dsc.monitorLock = false
            break taskExecLoop
        var count = dsc.buddies.len
        for w in dsc.buddies.nextValues:
          count.dec
          if worker.runPool(count == 0):
            break # `true` => stop
        dsc.monitorLock = false

      else:
        # Rotate connection table so the most used entry is at the top/right
        # end. So zombies will end up leftish.
        discard dsc.buddies.lruFetch(peer.hash)

        # Multi mode
        if worker.ctrl.multiOk:
          if not dsc.singleRunLock:
            dsc.activeMulti.inc
            # Continue doing something, work a bit
            await worker.runMulti()
            dsc.activeMulti.dec

        elif dsc.singleRunLock:
          # Some other process is running single mode
          discard # suspend some time at the end of loop body

        else:
          # Start single instance mode by grabbing `singleRunLock` (was
          # `false` as checked above).
          dsc.singleRunLock = true
          await worker.runSingle()
          dsc.singleRunLock = false

      # Dispatch daemon sevice if needed
      if not dsc.daemonRunning and dsc.ctx.daemon:
        asyncSpawn dsc.daemonLoop()

      # Check for termination
      if worker.ctrl.stopped:
        break taskExecLoop

      # Enforce minimum time spend on this loop so we never each 100% cpu load
      # caused by some empty sub-tasks which are out of this scheduler control.
      let
        elapsed = Moment.now() - startMoment
        suspend = if execLoopTimeElapsedMin <= elapsed: execLoopTaskSwitcher
                  else: execLoopTimeElapsedMin - elapsed
      await sleepAsync suspend
      # End while

  # Note that `runStart()` was dispatched in `onPeerConnected()`
  worker.ctrl.stopped = true
  worker.runStop()


proc onPeerConnected[S,W](dsc: RunnerSyncRef[S,W]; peer: Peer) =
  mixin runStart, runStop
  # Check for known entry (which should not exist.)
  let
    maxWorkers = dsc.ctx.buddiesMax
    nPeers = dsc.pool.len
    nWorkers = dsc.buddies.len
  if dsc.buddies.hasKey(peer.hash):
    trace "Reconnecting zombie peer ignored", peer, nPeers, nWorkers, maxWorkers
    return

  # Initialise worker for this peer
  let buddy = RunnerBuddyRef[S,W](
    dsc:    dsc,
    worker: BuddyRef[S,W](
      ctx:  dsc.ctx,
      ctrl: BuddyCtrlRef(),
      peer: peer))
  if not buddy.worker.runStart():
    trace "Ignoring useless peer", peer, nPeers, nWorkers, maxWorkers
    buddy.worker.ctrl.zombie = true
    return

  # Check for table overflow. An overflow might happen if there are zombies
  # in the table (though preventing them from re-connecting for a while.)
  if dsc.ctx.buddiesMax <= nWorkers:
    let leastPeer = dsc.buddies.shift.value.data
    if leastPeer.worker.ctrl.zombie:
      trace "Dequeuing zombie peer",
        oldest=leastPeer.worker, nPeers, nWorkers=dsc.buddies.len, maxWorkers
      discard
    else:
      # This could happen if there are idle entries in the table, i.e.
      # somehow hanging runners.
      trace "Peer table full! Dequeuing least used entry",
        oldest=leastPeer.worker, nPeers, nWorkers=dsc.buddies.len, maxWorkers
      leastPeer.worker.ctrl.zombie = true
      leastPeer.worker.runStop()

  # Add peer entry
  discard dsc.buddies.lruAppend(peer.hash, buddy, dsc.ctx.buddiesMax)

  trace "Running peer worker", peer, nPeers,
    nWorkers=dsc.buddies.len, maxWorkers

  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  let
    nPeers = dsc.pool.len
    maxWorkers = dsc.ctx.buddiesMax
    nWorkers = dsc.buddies.len
    rc = dsc.buddies.eq(peer.hash)
  if rc.isErr:
    debug "Disconnected, unregistered peer", peer, nPeers, nWorkers, maxWorkers
    return
  if rc.value.worker.ctrl.zombie:
    # Don't disconnect, leave them fall out of the LRU cache. The effect is,
    # that reconnecting might be blocked, for a while.
    trace "Disconnected, zombie", peer, nPeers, nWorkers, maxWorkers
  else:
    rc.value.worker.ctrl.stopped = true # in case it is hanging somewhere
    dsc.buddies.del(peer.hash)
    trace "Disconnected buddy", peer, nPeers,
      nWorkers=dsc.buddies.len, maxWorkers

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initSync*[S,W](
    dsc: RunnerSyncRef[S,W];
    node: EthereumNode;
    chain: ChainRef,
    slots: int;
    noisy = false) =
  ## Constructor
  # Leave one extra slot so that it can holds a *zombie* even if all slots
  # are full. The effect is that a re-connect on the latest zombie will be
  # rejected as long as its worker descriptor is registered.
  dsc.ctx = CtxRef[S](
    ethWireCtx: cast[EthWireRef](node.protocolState protocol.eth),
    buddiesMax: max(1, slots + 1),
    chain: chain)
  dsc.pool = node.peerPool
  dsc.tickerOk = noisy
  dsc.buddies.init(dsc.ctx.buddiesMax)

proc startSync*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Set up `PeerObserver` handlers and start syncing.
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
    if dsc.ctx.daemon:
      asyncSpawn dsc.daemonLoop()
    return true

proc stopSync*[S,W](dsc: RunnerSyncRef[S,W]) =
  ## Stop syncing and free peer handlers .
  mixin runRelease
  dsc.pool.delObserver(dsc)

  # Gracefully shut down async services
  dsc.shutdown = true
  for buddy in dsc.buddies.nextValues:
    buddy.worker.ctrl.stopped = true
  dsc.ctx.daemon = false

  # Final shutdown (note that some workers might still linger on)
  dsc.ctx.runRelease()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
