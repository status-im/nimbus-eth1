# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
## *runDaemon(ctx: CtxRef[S]) {.async.}*
##   Global background job that will be re-started as long as the variable
##   `ctx.daemon` is set `true`. If that job was stopped due to re-setting
##   `ctx.daemon` to `false`, it will be restarted next after it was reset
##   as `true` not before there is some activity on the `runPool()`, or
##   `runPeer()` functions.
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
## *runPeer(buddy: BuddyRef[S,W]) {.async.}*
##   This peer worker method is repeatedly invoked (exactly one per peer) while
##   the `buddy.ctrl.poolMode` flag is set `false`.
##
##   These peer worker methods run concurrently in `async` mode.
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

  RunnerSyncRef*[S,W] = ref object
    ## Module descriptor
    ctx*: CtxRef[S]             ## Shared data
    pool: PeerPool              ## For starting the system
    buddies: ActiveBuddies[S,W] ## LRU cache with worker descriptors
    daemonRunning: bool         ## Run global background job
    monitorLock: bool           ## Monitor mode is activated
    activeMulti: int            ## Number of activated runners in multi-mode
    shutdown: bool              ## Internal shut down flag

  RunnerBuddyRef[S,W] = ref object
    ## Per worker peer descriptor
    dsc: RunnerSyncRef[S,W]     ## Scheduler descriptor
    worker: BuddyRef[S,W]       ## Worker peer data
    zombified: Moment           ## When it became undead (if any)

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
  mixin runPeer, runPool, runStop
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
        while 0 < dsc.activeMulti:
          await sleepAsync execLoopPollingTime
          if worker.ctrl.stopped:
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

        # Peer mode
        dsc.activeMulti.inc
        # Continue doing something, work a bit
        await worker.runPeer()
        dsc.activeMulti.dec

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
  if worker.ctrl.running:
    # So shutdown was called
    worker.ctrl.stopped = true
  worker.runStop()


proc onPeerConnected[S,W](dsc: RunnerSyncRef[S,W]; peer: Peer) =
  mixin runStart, runStop
  # Check for known entry (which should not exist.)
  let
    maxWorkers {.used.} = dsc.ctx.buddiesMax
    nPeers {.used.} = dsc.pool.len
    zombie = dsc.buddies.eq peer.key
  if zombie.isOk:
    let
      now = Moment.now()
      ttz = zombie.value.zombified + zombieTimeToLinger
    if ttz < Moment.now():
      trace "Reconnecting zombie peer ignored", peer,
        nPeers, nWorkers=dsc.buddies.len, maxWorkers, canRequeue=(now-ttz)
      return
    # Zombie can be removed from the database
    dsc.buddies.del peer.key
    trace "Zombie peer timeout, ready for requeing", peer,
      nPeers, nWorkers=dsc.buddies.len, maxWorkers

  # Initialise worker for this peer
  let buddy = RunnerBuddyRef[S,W](
    dsc:    dsc,
    worker: BuddyRef[S,W](
      ctx:  dsc.ctx,
      ctrl: BuddyCtrlRef(),
      peer: peer))
  if not buddy.worker.runStart():
    trace "Ignoring useless peer", peer, nPeers,
      nWorkers=dsc.buddies.len, maxWorkers
    buddy.worker.ctrl.zombie = true
    return

  # Check for table overflow which might happen any time, not only if there are
  # to many zombies in the table (which are prevented from being re-accepted
  # while keept in the local table.)
  #
  # In the past, one could not rely on the peer pool for having the number of
  # connections limited.
  if dsc.ctx.buddiesMax <= dsc.buddies.len:
    let
      leastVal = dsc.buddies.shift.value # unqueue first/least item
      oldest = leastVal.data.worker
    if oldest.isNil:
      trace "Dequeuing zombie peer",
        # Fake `Peer` pretty print for `oldest`
        oldest=("Node[" & $leastVal.key.address & "]"),
        since=leastVal.data.zombified, nPeers, nWorkers=dsc.buddies.len,
        maxWorkers
      discard
    else:
      # This could happen if there are idle entries in the table, i.e.
      # somehow hanging runners.
      trace "Peer table full! Dequeuing least used entry", oldest,
        nPeers, nWorkers=dsc.buddies.len, maxWorkers
      # Setting to `zombie` will trigger the worker to terminate (if any.)
      oldest.ctrl.zombie = true

  # Add peer entry
  discard dsc.buddies.lruAppend(peer.key, buddy, dsc.ctx.buddiesMax)

  # trace "Running peer worker", peer, nPeers,
  #   nWorkers=dsc.buddies.len, maxWorkers
  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  let
    nPeers = dsc.pool.len
    maxWorkers = dsc.ctx.buddiesMax
    nWorkers = dsc.buddies.len
    rc = dsc.buddies.eq peer.key
  if rc.isErr:
    debug "Disconnected, unregistered peer", peer, nPeers, nWorkers, maxWorkers
    discard
  elif rc.value.worker.isNil:
    # Re-visiting zombie
    trace "Ignore zombie", peer, nPeers, nWorkers, maxWorkers
    discard
  elif rc.value.worker.ctrl.zombie:
    # Don't disconnect, leave them fall out of the LRU cache. The effect is,
    # that reconnecting might be blocked, for a while. For few peers cases,
    # the start of zombification is registered so that a zombie can eventually
    # be let die and buried.
    rc.value.worker = nil
    rc.value.dsc = nil
    rc.value.zombified = Moment.now()
    trace "Disconnected, zombie", peer, nPeers, nWorkers, maxWorkers
  else:
    rc.value.worker.ctrl.stopped = true # in case it is hanging somewhere
    dsc.buddies.del peer.key
    # trace "Disconnected buddy", peer, nPeers,
    #   nWorkers=dsc.buddies.len, maxWorkers

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
  dsc.ctx = CtxRef[S](buddiesMax: max(1, slots + 1))

  dsc.pool = node.peerPool
  dsc.buddies.init(dsc.ctx.buddiesMax)

proc startSync*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Set up `PeerObserver` handlers and start syncing.
  mixin runSetup
  # Initialise sub-systems
  if dsc.ctx.runSetup():
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
