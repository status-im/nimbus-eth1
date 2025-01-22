# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
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
## *runSetup(ctx: CtxRef[S]): bool*
##   Global set up. This function will be called before any worker peer is
##   started. If that function returns `false`, no worker peers will be run.
##
##   Also, this function should decide whether the `runDaemon()` job will be
##   started next by controlling the `ctx.daemon` flag (default is `false`.)
##
## *runRelease(ctx: CtxRef[S])*
##   Global clean up, done with all the worker peers.
##
## *runDaemon(ctx: CtxRef[S]) {.async: (raises: []).}*
##   Global background job that will be re-started as long as the variable
##   `ctx.daemon` is set `true`.
##
## *runTicker(ctx: CtxRef[S])*
##   Global background job that is started every few seconds. It is to be
##   intended for updating metrics, debug logging etc.
##
##
## *runStart(buddy: BuddyRef[S,W]): bool*
##   Initialise a new worker peer.
##
## *runStop(buddy: BuddyRef[S,W])*
##   Clean up this worker peer.
##
##
## *runPool(buddy: BuddyRef[S,W], last: bool; laps: int): bool*
##   Once started, the function `runPool()` is called for all worker peers in
##   sequence as long as the function returns `false`. There will be no other
##   `runPeer()` functions (see below) activated while `runPool()` is active.
##
##   This procedure is started if the global flag `buddy.ctx.poolMode` is set
##   `true` (default is `false`.) The flag will be automatically reset before
##   the loop starts. Re-setting it again results in repeating the loop. The
##   argument `laps` (starting with `0`) indicated the currend lap of the
##   repeated loops. To avoid continous looping, the number of `laps` is
##   limited (see `execPoolModeMax`, below.)
##
##   The argument `last` is set `true` if the last entry of the current loop
##   has been reached.
##
##   Note that this function does *not* run in `async` mode.
##
##
## *runPeer(buddy: BuddyRef[S,W]) {.async: (raises: []).}*
##   This peer worker method is repeatedly invoked (exactly one per peer) while
##   the `buddy.ctrl.poolMode` flag is set `false`.
##
##   These peer worker methods run concurrently in `async` mode.
##
##
## These are the control variables that can be set from within the above
## listed method/interface functions.
##
## *buddy.ctx.poolMode*
##   Activate `runPool()` workers loop if set `true` (default is `false`.)
##
## *buddy.ctx.daemon*
##   Activate `runDaemon()` background job if set `true`(default is `false`.)
##
##
## Additional import files needed when using this template:
## * eth/[common, p2p]
## * chronicles
## * chronos
## * stew/[interval_set, sorted_set],
## * "."/[sync_desc, sync_sched, protocol]
##
{.push raises: [].}

import
  std/hashes,
  chronos,
  eth/[p2p, p2p/peer_pool],
  stew/keyed_queue,
  ./sync_desc

type
  ActiveBuddies[S,W] = ##\
    ## List of active workers, using `Hash(Peer)` rather than `Peer`
    KeyedQueue[ENode,RunnerBuddyRef[S,W]]

  RunCtrl = enum
    terminated = 0
    shutdown
    running

  RunnerSyncRef*[S,W] = ref object
    ## Module descriptor
    ctx*: CtxRef[S]             ## Shared data
    pool: PeerPool              ## For starting the system
    buddiesMax: int             ## Max number of buddies
    buddies: ActiveBuddies[S,W] ## LRU cache with worker descriptors
    daemonRunning: bool         ## Running background job (in async mode)
    tickerRunning: bool         ## Running background ticker
    monitorLock: bool           ## Monitor mode is activated (non-async mode)
    activeMulti: int            ## Number of async workers active/running
    runCtrl: RunCtrl            ## Start/stop control

  RunnerBuddyRef[S,W] = ref object
    ## Per worker peer descriptor
    dsc: RunnerSyncRef[S,W]     ## Scheduler descriptor
    worker: BuddyRef[S,W]       ## Worker peer data
    zombified: Moment           ## Time when it became undead (if any)
    isRunning: bool             ## Peer worker is active (in async mode)

const
  zombieTimeToLinger = 20.seconds
    ## Maximum time a zombie is kept on the database.

  execLoopTimeElapsedMin = 50.milliseconds
    ## Minimum elapsed time an exec loop needs for a single lap. If it is
    ## faster, asynchroneous sleep seconds are added. in order to avoid
    ## cpu overload.

  execLoopTaskSwitcher = 1.nanoseconds
    ## Asynchroneous waiting time at the end of an exec loop unless some sleep
    ## seconds were added as decribed by `execLoopTimeElapsedMin`, above.

  execLoopPollingTime = 50.milliseconds
    ## Single asynchroneous time interval wait state for event polling

  execPoolModeLoopMax = 100
    ## Avoids continuous looping

  termWaitPollingTime = 10.milliseconds
    ## Wait for instance to have terminated for shutdown

  tickerWaitInterval = 5.seconds
    ## Ticker loop interval

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash*(key: ENode): Hash =
  ## Mixin, needed for `buddies` table key comparison. Needs to be a public
  ## function technically although it should be seen logically as a private
  ## one.
  var h: Hash = 0
  h = h !& hashes.hash(key.pubkey.toRaw)
  h = h !& hashes.hash(key.address)
  !$h

proc key(peer: Peer): ENode =
  ## Map to key for below table methods.
  peer.remote.node

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc terminate[S,W](dsc: RunnerSyncRef[S,W]) {.async.} =
  ## Request termination and wait for sub-tasks to finish
  mixin runRelease

  if dsc.runCtrl == running:
    # Gracefully shut down async services
    dsc.runCtrl = shutdown
    dsc.ctx.daemon = false

    # Wait for workers and daemon to have terminated
    while 0 < dsc.buddies.len:
      for w in dsc.buddies.nextPairs:
        if w.data.isRunning:
          w.data.worker.ctrl.stopped = true
        else:
          dsc.buddies.del w.key # this is OK to delete
      # Activate async jobs so they can finish
      try:
        waitFor sleepAsync termWaitPollingTime
      except CancelledError:
        trace "Shutdown: peer timeout was cancelled", nWorkers=dsc.buddies.len

    while dsc.daemonRunning:
      # Activate async job so it can finish
      try:
        await sleepAsync termWaitPollingTime
      except CancelledError:
        trace "Shutdown: daemon timeout was cancelled", nWorkers=dsc.buddies.len

    # Final shutdown
    dsc.ctx.runRelease()

    # Remove call back from pool manager. This comes last as it will
    # potentially unlink references which are used in the worker instances
    # (e.g. peer for logging.)
    dsc.pool.delObserver(dsc)

    # Clean up, free memory from sub-objects
    dsc.ctx = CtxRef[S]()
    dsc.runCtrl = terminated


proc daemonLoop[S,W](dsc: RunnerSyncRef[S,W]) {.async: (raises: []).} =
  mixin runDaemon

  if dsc.ctx.daemon and dsc.runCtrl == running:
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
      try:
        await sleepAsync suspend
      except CancelledError:
        # Stop on error (must not end up in busy-loop). If the activation flag
        # `dsc.ctx.daemon` remains `true`, the deamon will be re-started from
        # the worker loop in due time.
        trace "Deamon loop sleep was cancelled", nWorkers=dsc.buddies.len
        break
      # End while

  dsc.daemonRunning = false

proc tickerLoop[S,W](dsc: RunnerSyncRef[S,W]) {.async: (raises: []).} =
  mixin runTicker

  if dsc.runCtrl == running:
    dsc.tickerRunning = true

    while true:
      # Dispatch daemon sevice if needed
      if not dsc.daemonRunning and dsc.ctx.daemon:
        asyncSpawn dsc.daemonLoop()

      # Run ticker job
      dsc.ctx.runTicker()

      try:
        await sleepAsync tickerWaitInterval
      except CancelledError:
        trace "Ticker loop sleep was cancelled"
        break

  dsc.tickerRunning = false


proc workerLoop[S,W](buddy: RunnerBuddyRef[S,W]) {.async: (raises: []).} =
  mixin runPeer, runPool, runStop
  let
    dsc = buddy.dsc
    ctx = dsc.ctx
    worker = buddy.worker
    peer = worker.peer

  # Continue until stopped
  block taskExecLoop:
    buddy.isRunning = true

    proc isShutdown(): bool =
      dsc.runCtrl != running

    proc isActive(): bool =
      worker.ctrl.running and not isShutdown()

    while isActive():
      # Enforce minimum time spend on this loop
      let startMoment = Moment.now()

      if dsc.monitorLock:
        discard # suspend some time at the end of loop body

      # Invoke `runPool()` over all buddies if requested
      elif ctx.poolMode:
        # Grab `monitorLock` (was `false` as checked above) and wait until
        # clear to run as the only activated instance.
        dsc.monitorLock = true
        while 0 < dsc.activeMulti:
          try:
            await sleepAsync execLoopPollingTime
          except CancelledError:
            # must not end up in busy-loop
            dsc.monitorLock = false
            break taskExecLoop
          if not isActive():
            dsc.monitorLock = false
            break taskExecLoop

        var count = 0
        while count < execPoolModeLoopMax:
          ctx.poolMode = false
          # Pool mode: stop this round if returned `true`,
          #            last invocation this round with `true` argument
          var delayed = BuddyRef[S,W](nil)
          for w in dsc.buddies.nextValues:
            # Execute previous (aka delayed) item (unless first)
            if delayed.isNil or not delayed.runPool(last=false, laps=count):
              delayed = w.worker
            else:
              delayed = nil # not executing any final item
              break # `true` => stop
            # Shutdown in progress?
            if isShutdown():
              dsc.monitorLock = false
              break taskExecLoop
          if not delayed.isNil:
            discard delayed.runPool(last=true, laps=count) # final item
          if not ctx.poolMode:
            break
          count.inc
        dsc.monitorLock = false

      else:
        # Rotate connection table so the most used entry is at the top/right
        # end. So zombies will end up leftish.
        discard dsc.buddies.lruFetch peer.key

        # Peer worker in async mode
        dsc.activeMulti.inc
        # Continue doing something, work a bit
        await worker.runPeer()
        dsc.activeMulti.dec

      # Check for shutdown
      if isShutdown():
        worker.ctrl.stopped = true
        break taskExecLoop

      # Restart ticker sevice if needed
      if not dsc.tickerRunning:
        asyncSpawn dsc.tickerLoop()

      # Check for worker termination
      if worker.ctrl.stopped:
        break taskExecLoop

      # Enforce minimum time spend on this loop so we never each 100% cpu load
      # caused by some empty sub-tasks which are out of this scheduler control.
      let
        elapsed = Moment.now() - startMoment
        suspend = if execLoopTimeElapsedMin <= elapsed: execLoopTaskSwitcher
                  else: execLoopTimeElapsedMin - elapsed
      try:
        await sleepAsync suspend
      except CancelledError:
        trace "Peer loop sleep was cancelled", peer, nWorkers=dsc.buddies.len
        break # stop on error (must not end up in busy-loop)
      # End while

  # Note that `runStart()` was dispatched in `onPeerConnected()`
  worker.runStop()
  buddy.isRunning = false


proc onPeerConnected[S,W](dsc: RunnerSyncRef[S,W]; peer: Peer) =
  mixin runStart, runStop

  # Ignore if shutdown is processing
  if dsc.runCtrl != running:
    return

  # Check for known entry (which should not exist.)
  let
    maxWorkers {.used.} = dsc.buddiesMax
    nPeers {.used.} = dsc.pool.len
    zombie = dsc.buddies.eq peer.key
  if zombie.isOk:
    let
      now = Moment.now()
      ttz = zombie.value.zombified + zombieTimeToLinger
    if ttz < Moment.now():
      if dsc.ctx.noisyLog: trace "Reconnecting zombie peer ignored", peer,
        nPeers, nWorkers=dsc.buddies.len, maxWorkers, canRequeue=(now-ttz)
      return
    # Zombie can be removed from the database
    dsc.buddies.del peer.key
    if dsc.ctx.noisyLog: trace "Zombie peer timeout, ready for requeing", peer,
      nPeers, nWorkers=dsc.buddies.len, maxWorkers

  # Initialise worker for this peer
  let buddy = RunnerBuddyRef[S,W](
    dsc:    dsc,
    worker: BuddyRef[S,W](
      ctx:  dsc.ctx,
      ctrl: BuddyCtrlRef(),
      peer: peer))
  if not buddy.worker.runStart():
    if dsc.ctx.noisyLog: trace "Ignoring useless peer", peer, nPeers,
      nWorkers=dsc.buddies.len, maxWorkers
    buddy.worker.ctrl.zombie = true
    return

  # Check for table overflow which might happen any time, not only if there are
  # to many zombies in the table (which are prevented from being re-accepted
  # while keept in the local table.)
  #
  # In the past, one could not rely on the peer pool for having the number of
  # connections limited.
  if dsc.buddiesMax <= dsc.buddies.len:
    let
      leastVal = dsc.buddies.shift.value # unqueue first/least item
      oldest = leastVal.data.worker
    if oldest.isNil:
      if dsc.ctx.noisyLog: trace "Dequeuing zombie peer",
        # Fake `Peer` pretty print for `oldest`
        oldest=("Node[" & $leastVal.key.address & "]"),
        since=leastVal.data.zombified, nPeers, nWorkers=dsc.buddies.len,
        maxWorkers
      discard
    else:
      # This could happen if there are idle entries in the table, i.e.
      # somehow hanging runners.
      if dsc.ctx.noisyLog: trace "Peer table full! Dequeuing least used entry",
        oldest, nPeers, nWorkers=dsc.buddies.len, maxWorkers
      # Setting to `zombie` will trigger the worker to terminate (if any.)
      oldest.ctrl.zombie = true

  # Add peer entry
  discard dsc.buddies.lruAppend(peer.key, buddy, dsc.buddiesMax)

  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  let
    nPeers = dsc.pool.len
    maxWorkers = dsc.buddiesMax
    nWorkers = dsc.buddies.len
    rc = dsc.buddies.eq peer.key
  if rc.isErr:
    if dsc.ctx.noisyLog: debug "Disconnected, unregistered peer", peer,
      nPeers, nWorkers, maxWorkers
  elif rc.value.worker.isNil:
    # Re-visiting zombie
    if dsc.ctx.noisyLog: trace "Ignore zombie", peer,
      nPeers, nWorkers, maxWorkers
  elif rc.value.worker.ctrl.zombie:
    # Don't disconnect, leave them fall out of the LRU cache. The effect is,
    # that reconnecting might be blocked, for a while. For few peers cases,
    # the start of zombification is registered so that a zombie can eventually
    # be let die and buried.
    rc.value.worker = nil
    rc.value.dsc = nil
    rc.value.zombified = Moment.now()
    if dsc.ctx.noisyLog: trace "Disconnected, zombie", peer,
      nPeers, nWorkers, maxWorkers
  else:
    rc.value.worker.ctrl.stopped = true # in case it is hanging somewhere
    dsc.buddies.del peer.key

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initSync*[S,W](
    dsc: RunnerSyncRef[S,W];
    node: EthereumNode;
    slots: int;
      ) =
  ## Constructor
  # Leave one extra slot so that it can holds a *zombie* even if all slots
  # are full. The effect is that a re-connect on the latest zombie will be
  # rejected as long as its worker descriptor is registered.
  dsc.buddiesMax = max(1, slots + 1)
  dsc.pool = node.peerPool
  dsc.buddies.init(dsc.buddiesMax)
  dsc.ctx = CtxRef[S]()


proc startSync*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Set up `PeerObserver` handlers and start syncing.
  mixin runSetup

  if dsc.runCtrl == terminated:
    # Initialise sub-systems
    if dsc.ctx.runSetup():
      dsc.runCtrl = running

      var po = PeerObserver(
        onPeerConnected: proc(p: Peer) {.gcsafe.} =
          dsc.onPeerConnected(p),
        onPeerDisconnected: proc(p: Peer) {.gcsafe.} =
          dsc.onPeerDisconnected(p))

      po.setProtocol eth
      dsc.pool.addObserver(dsc, po)
      asyncSpawn dsc.tickerLoop()
      return true


proc stopSync*[S,W](dsc: RunnerSyncRef[S,W]) {.async.} =
  ## Stop syncing and free peer handlers .
  await dsc.terminate()


proc isRunning*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Check start/stop state
  dsc.runCtrl == running

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
