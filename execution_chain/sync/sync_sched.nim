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
## *runSetup(ctx: CtxRef[S,W]): bool*
##   Global set up. This function will be called before any worker peer is
##   started. If that function returns `false`, no worker peers will be run.
##
##   Also, this function should decide whether the `runDaemon()` job will be
##   started next by controlling the `ctx.daemon` flag (default is `false`.)
##
## *runRelease(ctx: CtxRef[S,W])*
##   Global clean up, done with all the worker peers.
##
## *runDaemon(ctx: CtxRef[S,W]) {.async: (raises: []).}*
##   Global background job that will be re-started as long as the variable
##   `ctx.daemon` is set `true`.
##
##   The function returns a suggested idle time to wait for the next invocation.
##
## *runTicker(ctx: CtxRef[S,W])*
##   Global background job that is started every few seconds. It is to be
##   intended for updating metrics, debug logging etc.
##
##
## *runStart(buddy: SyncPeerRef[S,W]): bool*
##   Initialise a new worker peer.
##
## *runStop(buddy: SyncPeerRef[S,W])*
##   Clean up this worker peer.
##
##
## *runPool(buddy: SyncPeerRef[S,W], last: bool; laps: int): bool*
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
## *runPeer(buddy: SyncPeerRef[S,W]) {.async: (raises: []).}*
##   This peer worker method is repeatedly invoked (exactly one per peer) while
##   the `buddy.ctrl.poolMode` flag is set `false`. All workers run
##   concurrently in `async` mode.
##
##   The function returns a suggested idle time to wait for the next invocation.
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
  std/[algorithm, hashes, sets, sequtils, strutils],
  pkg/[chronos, minilru],
  ../networking/[p2p, peer_pool],
  ../utils/utils,
  ./[sync_desc, wire_protocol]

type
  ActivePeers[S,W] = LruCache[Hash,RunnerPeerRef[S,W]]
    ## List of active workers, using `Hash(Peer)` rather than `Peer` as a key.

  ZombiePeers = LruCache[Hash,chronos.Moment]
    ## List of active workers, using `Hash(Peer)` rather than `Peer` as a key.

  PeerByIP = LruCache[IpAddress,HashSet[Port]]
    ## Register active peers by IP address. This allows to identify peers
    ## with the same IP address but different ports.

  RunCtrl = enum
    terminated = 0
    shutdown
    running

  PeerProtoCheck = ref object
    hasProto: AcceptPeerOk      ## Sub protocol selector closure
    acceptPeer: AcceptPeerOk    ## Can accept protocol enabled by `hasProto()`

  RunnerPeerRef[S,W] = ref object
    ## Per worker peer descriptor
    dsc: RunnerSyncRef[S,W]     ## Scheduler descriptor
    worker: SyncPeerRef[S,W]    ## Worker peer data
    zombified: Moment           ## Time when it became undead (if any)

  # ---- public types ----

  AcceptPeerOk* = proc(peer: Peer): bool {.gcsafe, raises: [].}

  RunnerSyncRef*[S,W] = ref object of RootRef
    ## Module descriptor
    ctx*: CtxRef[S,W]           ## Shared data
    peerPool: PeerPool          ## For starting the system
    syncPeers: ActivePeers[S,W] ## LRU cache with worker descriptors
    zombies: ZombiePeers        ## Blocked from re-connect peers
    orphans: ActivePeers[S,W]   ## Temporary overflow cache for LRU
    peerByIP: PeerByIP          ## By IP address registry
    maxPortsPerIp: int          ## Max size of `HashSet[Port]` in `peerByIP{}`
    daemonRunning: bool         ## Running background job (in async mode)
    tickerRunning: bool         ## Running background ticker
    monitorLock: bool           ## Monitor mode is activated (non-async mode)
    activeMulti: int            ## Number of async workers active/running
    runCtrl: RunCtrl            ## Overall scheduler start/stop control
    po: PeerObserver            ## P2p protocol handler environment
    filter: seq[PeerProtoCheck] ## List of p2p sub-protocol handler filters

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
# Private debugging helpers
# ------------------------------------------------------------------------------

template noisy[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Log a bit more (typically while syncer is activated)
  true or
  dsc.ctx.noisyLog

func toStr(w: HashSet[Port]): string =
  "{" & w.toSeq.mapIt(it.uint).sorted.mapIt($it).join(",") & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc key(peer: Peer): Hash =
  ## Map to table key.
  var h: Hash = 0
  h = h !& hashes.hash(peer.remote.node.pubkey.toRaw)
  h = h !& hashes.hash(peer.remote.node.address)
  !$h

proc nSyncPeers[S,W](dsc: RunnerSyncRef[S,W]): int =
  dsc.syncPeers.len + dsc.orphans.len

template lruReset(db: untyped): untyped =
  ## Clear LRU list
  db = typeof(db).init db.capacity

proc alwaysAcceptPeerOk(peer: Peer): bool =
  ## Some default call back function
  true

# ------------------------------------------------------------------------------
# Private constructor helpers
# ------------------------------------------------------------------------------

proc getSyncPeerFn[S,W](dsc: RunnerSyncRef[S,W]): GetSyncPeerFn[S,W] =
  ## Get particular active syncer peer (aka buddy)
  result = proc(peerID: Hash): SyncPeerRef[S,W] =
    dsc.syncPeers.peek(peerID).isErrOr:
      return value.worker
    dsc.orphans.peek(peerID).isErrOr:
      return value.worker
    # SyncPeerRef[S,W](nil)

proc getSyncPeersFn[S,W](dsc: RunnerSyncRef[S,W]): GetSyncPeersFn[S,W] =
  ## Get a list of descriptor all active syncer peers (aka buddies)
  result = proc(): seq[SyncPeerRef[S,W]] =
    var list: seq[SyncPeerRef[S,W]]
    for w in dsc.syncPeers.values:
      list.add w.worker
    for w in dsc.orphans.values:
      list.add w.worker
    list

proc nSyncPeersFn[S,W](dsc: RunnerSyncRef[S,W]): NSyncPeersFn[S,W] =
  ## Efficient version of `dsc.getSyncPeersFn().len`
  result = proc(): int =
    dsc.nSyncPeers()

# ------------------------------------------------------------------------------
# Private by-IP registry helpers
# ------------------------------------------------------------------------------

proc unregisterByIP[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  ## Remove peer from IP address list
  ##
  var ports = dsc.peerByIP.peek(peer.remote.node.address.ip).valueOr:
    return
  let pLen = ports.len
  ports.excl peer.remote.node.address.tcpPort
  ports.excl peer.remote.node.address.udpPort
  if ports.len == 0:
    dsc.peerByIP.del peer.remote.node.address.ip
  elif ports.len != pLen:
    dsc.peerByIP.put(peer.remote.node.address.ip, ports)

proc registerByIP[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  ## Add peer to IP address list
  ##
  var ports: HashSet[Port]
  dsc.peerByIP.peek(peer.remote.node.address.ip).isErrOr:
    ports = value
  if 0 < peer.remote.node.address.udpPort.uint:
    ports.incl peer.remote.node.address.udpPort
  if 0 < peer.remote.node.address.tcpPort.uint:
    ports.incl peer.remote.node.address.tcpPort
  dsc.peerByIP.put(peer.remote.node.address.ip, ports)

proc acceptByIP[S,W](dsc: RunnerSyncRef[S,W], peer: Peer): bool =
  ## Check, whether a new peer can be registered by the following criteria:
  ## * Peer must not have been registered in the `syncPeers[]` table
  ## * There must be a free slot in the `peerByIP[]` table
  ##
  # Check whether peer exists, already
  dsc.syncPeers.peek(peer.key).isErrOr:
    info "Same peer ID active, rejecting new peer",
      peer=value.worker.peer, newPeer=peer, nSyncPeers=dsc.nSyncPeers(),
      nSyncPeersMax=dsc.syncPeers.capacity, nPoolPeers=dsc.peerPool.len
    return false

  var ports = dsc.peerByIP.peek(peer.remote.node.address.ip).valueOr:
    return true

  if ports.len < dsc.maxPortsPerIp:
    return true

  # Port table full. Cannot add this peer.
  if dsc.noisy: trace "Too many peers with same IP, rejected", peer,
    otherPorts=ports.toStr, nSyncPeers=dsc.nSyncPeers(),
    nSyncPeersMax=dsc.syncPeers.capacity, nPoolPeers=dsc.peerPool.len
  return false

# ------------------------------------------------------------------------------
# Private handlers, action loops
# ------------------------------------------------------------------------------

proc daemonLoop[S,W](dsc: RunnerSyncRef[S,W]) {.async: (raises: []).} =
  mixin runDaemon

  if dsc.ctx.daemon and dsc.runCtrl == running:
    dsc.daemonRunning = true

    # Continue until stopped
    while true:
      # Enforce minimum time spend on this loop
      let
        startMoment = Moment.now()
        idleTime = await dsc.ctx.runDaemon()

      if not dsc.ctx.daemon:
        break

      # Enforce minimum time spend on this loop so we never each 100% cpu load
      # caused by some empty sub-tasks which are out of this scheduler control.
      let
        elapsed = Moment.now() - startMoment
        suspend = if execLoopTimeElapsedMin <= elapsed: execLoopTaskSwitcher
                  else: execLoopTimeElapsedMin - elapsed
      try:
        await sleepAsync max(suspend, idleTime)
      except CancelledError:
        # Stop on error (must not end up in busy-loop). If the activation flag
        # `dsc.ctx.daemon` remains `true`, the deamon will be re-started from
        # the worker loop in due time.
        trace "Deamon loop sleep was cancelled",
          nCachedWorkers=dsc.nSyncPeers()
        break
      # End while

  dsc.daemonRunning = false


proc tickerLoop[S,W](dsc: RunnerSyncRef[S,W]) {.async: (raises: []).} =
  mixin runTicker

  if dsc.runCtrl == running:
    dsc.tickerRunning = true

    while dsc.runCtrl == running:
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


proc workerLoop[S,W](buddy: RunnerPeerRef[S,W]) {.async: (raises: []).} =
  mixin runPeer, runPool, runStop

  let
    dsc = buddy.dsc
    ctx = dsc.ctx
    worker = buddy.worker
    peer = worker.peer
    peerID = peer.key

  # Continue until stopped
  block taskExecLoop:

    template isShutdown(): bool =
      dsc.runCtrl != running

    template isActive(): bool =
      worker.ctrl.running and not isShutdown()

    while isActive():
      # Enforce minimum time spend on this loop
      let startMoment = Moment.now()
      var idleTime: Duration # suggested by `runPeer()`

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
          var delayed = SyncPeerRef[S,W](nil)
          for w in dsc.syncPeers.values:
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
        # Rotate LRU connection table so this `worker` becomes most used
        # entry. As a consequence, zombies will end up as least used entries
        # and evicted first on LRU table overflow.
        discard dsc.syncPeers.get peerID

        # Peer worker in async mode
        dsc.activeMulti.inc
        # Continue doing something, work a bit
        idleTime = await worker.runPeer()
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
        await sleepAsync max(suspend, idleTime)
      except CancelledError:
        trace "Peer loop sleep was cancelled", peer,
          nSyncPeers=dsc.nSyncPeers(), nSyncPeersMax=dsc.syncPeers.capacity,
          nPoolPeers=dsc.peerPool.len
        break taskExecLoop # stop on error (must not end up in busy-loop)

      # Need to re-check after potential task switch
      if isShutdown() or worker.ctrl.stopped:
        worker.ctrl.stopped = true
        break taskExecLoop

      # End while

  # Note that `runStart()` was dispatched in `onPeerConnected()`
  worker.runStop()                # tell worker that this peer is done with

  if worker.ctrl.zombie:
    dsc.zombies.put(peerID, Moment.now())

  dsc.unregisterByIP peer         # unregister from IP list
  dsc.syncPeers.del peerID        # remove from syncer peer list
  dsc.orphans.del peerID          # in case it was evicted

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc terminate[S,W](dsc: RunnerSyncRef[S,W]) {.async: (raises: []).} =
  ## Request termination and wait for sub-tasks to finish
  mixin runRelease

  if dsc.runCtrl == running:
    # Gracefully shut down async services
    dsc.runCtrl = shutdown
    dsc.ctx.daemon = false

    # Wait for workers and daemon to have terminated
    while 0 < dsc.nSyncPeers():
      for buddy in dsc.syncPeers.values:
        # Tell async worker that it should terminate. This might be
        # needed for the worker apps. The scheuler tasks trigger on
        # `runCtrl == shutdown`, already.
        buddy.worker.ctrl.stopped = true
      # Wait for async worker to terminate
      try:
        waitFor sleepAsync termWaitPollingTime
      except CancelledError:
        trace "Shutdown: peer timeout was cancelled",
          nCachedWorkers=dsc.nSyncPeers()

    while dsc.daemonRunning or
          dsc.tickerRunning:
      # Activate async job so it can finish
      try:
        await sleepAsync termWaitPollingTime
      except CancelledError:
        trace "Shutdown: daemon timeout was cancelled",
          nCachedWorkers=dsc.nSyncPeers()

    # Final shutdown
    dsc.ctx.runRelease()
    dsc.runCtrl = terminated

    # Remove call back from pool manager. This comes last as it will
    # potentially unlink references which are used in the worker instances
    # (e.g. peer for logging.)
    dsc.peerPool.delObserver(dsc)


proc onPeerConnected[S,W](dsc: RunnerSyncRef[S,W]; peer: Peer) =
  mixin runStart

  # Ignore if shutdown processing
  if dsc.runCtrl != running:
    return

  block protoFilter:
    # Accept if accepted by some vetting filter
    for filter in dsc.filter:
      if filter.hasProto(peer) and
         filter.acceptPeer(peer):
        break protoFilter
    # Otherwise ignore
    if dsc.noisy: trace "No suitable protocol for peer", peer
    return # fail

  # Make sure that the overflow list can absorb an eviced peer temporarily
  if dsc.orphans.capacity <= dsc.orphans.len and
     dsc.syncPeers.capacity <= dsc.syncPeers.len:
    info "Igoring peer, all slots busy", peer, nSyncPeers=dsc.nSyncPeers(),
      nSyncPeersMax=dsc.syncPeers.capacity, nPoolPeers=dsc.peerPool.len
    return

  # Check for zombie
  let peerID = peer.key
  dsc.zombies.peek(peerID).isErrOr:
    let elapsed = Moment.now() - value
    if elapsed < zombieTimeToLinger:
      if dsc.noisy: trace "Reconnecting zombie peer ignored", peer,
        nSyncPeers=dsc.nSyncPeers(), nSyncPeersMax=dsc.syncPeers.capacity,
        nPoolPeers=dsc.peerPool.len,
        canReconnectIn=(zombieTimeToLinger-elapsed).toString(2)
      return
    # Otherwise remove zombie and accept `peer`
    dsc.zombies.del peerID

  # Check for known entry (which should not exist) or other restrictions.
  if not dsc.acceptByIP peer:
    return

  # Initialise worker for this peer
  let buddy = RunnerPeerRef[S,W](
    dsc:      dsc,
    worker:   SyncPeerRef[S,W](
      ctx:    dsc.ctx,
      peer:   peer,
      peerID: peerID))
  if not buddy.worker.runStart():
    if dsc.noisy: trace "Ignoring useless peer", peer,
      nSyncPeers=dsc.nSyncPeers(), nSyncPeersMax=dsc.syncPeers.capacity,
      nPoolPeers=dsc.peerPool.len
    return

  # Add peer entry. This might evict the least used entry from the LRU table.
  dsc.registerByIP peer
  for (evOk, evKey, evBuddy) in dsc.syncPeers.putWithEvicted(peerID, buddy):
    if evOk:
      let evPeer = evBuddy.worker.peer
      dsc.unregisterByIP evPeer
      dsc.orphans.put(evKey, evBuddy)      # adopt orphan temorarily

      # If it is set a zombie, it will be taken care of when the
      # `workerLoop()` finishes.
      if evBuddy.worker.ctrl.running:
        evBuddy.worker.ctrl.stopped = true

      if dsc.noisy: trace "Evicted peer", peer=evPeer,
        state=evBuddy.worker.ctrl.state, nSyncPeers=dsc.nSyncPeers(),
        nSyncPeersMax=dsc.syncPeers.capacity, nPoolPeers=dsc.peerPool.len

  # Hand over to worker loop
  asyncSpawn buddy.workerLoop()


proc onPeerDisconnected[S,W](dsc: RunnerSyncRef[S,W], peer: Peer) =
  ## Disconnect running peer
  dsc.syncPeers.peek(peer.key).isErrOr:
    if dsc.noisy: trace "Disconnecting peer", peer,
      nSyncPeers=dsc.nSyncPeers(), nSyncPeersMax=dsc.syncPeers.capacity,
      nPoolPeers=dsc.peerPool.len

    # If it is set a zombie, it will be taken care of when the
    # `workerLoop()` finishes.
    if value.worker.ctrl.running:
      value.worker.ctrl.stopped = true   # signals worker loop to terminate
    return

  discard                                # visual alignment

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initSync*[S,W](
    dsc: RunnerSyncRef[S,W];
    node: EthereumNode;
    slots: int;
    maxPortsPerIp = 2;
      ) =
  ## Constructor.
  ##
  ## As for the `maxPortsPerIp` parameter, it restricts active peers to at
  ## most this many sharing the same IP address, but differ in port numbers.
  ## When downloading, these peers typically show the same behaviour regarding
  ## data availablity. In case of non-availability for a worker application, a
  ## large pool of non-working peers with the same IP addtess may compete with
  ## the rest of peers for a single download slot which unnecessarily consumes
  ## time to find out.
  ##
  # Leave some extra slot so that it can holds a *zombie* even if all slots
  # are full. The effect is that a re-connect on the latest zombie will be
  # rejected as long as its worker descriptor is registered.
  dsc.peerPool = node.peerPool

  dsc.syncPeers = ActivePeers[S,W].init max(1, slots + 1)
  dsc.peerByIP = PeerByIP.init dsc.syncPeers.capacity
  dsc.maxPortsPerIp = max(1,maxPortsPerIp)

  # Half the `syncPeers[]` capacity for `zombies[]` and `orphans[]`
  dsc.orphans = ActivePeers[S,W].init(1 + dsc.syncPeers.capacity div 2)
  dsc.zombies = ZombiePeers.init dsc.orphans.capacity

  # Stash p2p protocol handlers to be further initalised, below
  dsc.po.onPeerConnected = proc(p: Peer) {.gcsafe.} =
    dsc.onPeerConnected(p)
  dsc.po.onPeerDisconnected = proc(p: Peer) {.gcsafe.} =
    dsc.onPeerDisconnected(p)

  # Public context with service functions
  dsc.ctx = CtxRef[S,W](
    node:         node,
    getSyncPeer:  dsc.getSyncPeerFn(),
    getSyncPeers: dsc.getSyncPeersFn(),
    nSyncPeers:   dsc.nSyncPeersFn())


proc addSyncProtocol*[S,W](
    dsc: RunnerSyncRef[S,W];
    PROTO: type;
    acceptPeer = AcceptPeerOk(nil);
      ) =
  ## Activate scheduler for a particular protocol. The filter argument
  ## function `acceptPeer` is run before any other connection handler. If
  ## the former returns `true`, processing goes ahead.
  ##
  dsc.po.addProtocol PROTO
  dsc.filter.add PeerProtoCheck(
    hasProto: proc(p: Peer): bool {.gcsafe.} =
      p.supports(PROTO),
    acceptPeer:
      (if acceptPeer.isNil: alwaysAcceptPeerOk else: acceptPeer))

# ---------

proc startSync*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  ## Activate `PeerObserver` handlers and start syncing.
  mixin runSetup

  if dsc.runCtrl == terminated:
    # Initialise sub-systems
    if dsc.ctx.runSetup():
      # Initialise descriptor for running, probably after an earlier
      # termination. The `dsc.ctx.pool` might containg inter session
      # data, so it is not reset here.
      dsc.runCtrl = running
      dsc.ctx.poolMode = false
      dsc.ctx.noisyLog = false
      dsc.syncPeers.lruReset()
      dsc.peerByIP.lruReset()
      dsc.orphans.lruReset()
      dsc.zombies.lruReset()

      # Activate protocol handlers
      dsc.peerPool.addObserver(dsc, dsc.po)
      if dsc.filter.len == 0:
        dsc.filter.add PeerProtoCheck(
          hasProto:   alwaysAcceptPeerOk,
          acceptPeer: alwaysAcceptPeerOk)

      asyncSpawn dsc.tickerLoop()
      return true

proc isRunning*[S,W](dsc: RunnerSyncRef[S,W]): bool =
  dsc.runCtrl != terminated

proc stopSync*[S,W](dsc: RunnerSyncRef[S,W]) {.async.} =
  ## Stop syncing and free peer handlers .
  if dsc.runCtrl != terminated:
    await dsc.terminate()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
