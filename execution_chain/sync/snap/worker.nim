# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos, minilru, results],
  pkg/[beacon_chain/process_state, stew/byteutils],
  ./worker/[download, helpers, cache_db, import_coredb,
            state_forward, start_stop, update, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc suspendDownload(buddy: SnapPeerRef) =
  ## Keep a peer on hold but do not ask for data until the `pivot` has
  ## advanced to a newer block number.
  buddy.only.stateExhausted = buddy.ctx.pool.pivotNum

func isSuspendedDownload(buddy: SnapPeerRef): bool =
  buddy.ctx.pool.pivotNum <= buddy.only.stateExhausted

proc suspendBal(buddy: SnapPeerRef) =
  ## Similar to `suspendDownload()`
  buddy.only.notAvailBal = buddy.ctx.pool.pivotNum

func snap2PeersAvailable(buddy: SnapPeerRef): bool =
  let nSnap2Peers = buddy.ctx.pool.nSnap2Peers
  if nSnap2Peers == 0:
    return false                                    # no peer is snap/2
  if buddy.nSnapPeers() <= nSnap2Peers:
    return true                                     # all peers are snap/2
  let pivotNum = buddy.ctx.pool.pivotNum
  for snapPeer in buddy.getSnapPeers():
    if snapPeer.only.supportsBal and                # is snap/2?
       snapPeer.only.notAvailBal < pivotNum:        # and not supended?
      return true                                   # ok, snap/2 available
  # false                                           # all snap/2 peers suspemded

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Global set up
  if ctx.setupServices info:
    return true
  error info & ": Setup failed, snap sync disabled"
  # false

proc release*(ctx: SnapCtxRef; info: static[string]) =
  ## Global clean up
  ctx.destroyServices()


proc start*(buddy: SnapPeerRef; info: static[string]): bool =
  ## Initialise worker peer
  let
    peer {.inject,used.} = $buddy.peer              # logging only
    ctx = buddy.ctx

  if not buddy.startSyncPeer():
    debug info & ": Failed", peer
    return false

  debug info & ": New peer", peer, nSyncPeers=ctx.nSyncPeers(),
    peerType=buddy.only.peerType, clientId=buddy.peer.clientId,
    supportsBal=buddy.only.supportsBal, nSnap2Peers=ctx.pool.nSnap2Peers
  true

proc stop*(buddy: SnapPeerRef; info: static[string]) =
  ## Clean up this peer
  debug info & ": Release peer", peer=buddy.peer,
    nSyncPeers=(buddy.ctx.nSyncPeers()-1), syncState=($buddy.syncState)
  buddy.stopSyncPeer()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runTicker*(ctx: SnapCtxRef; info: static[string]) =
  ## Global background job that is started every few seconds. It is to be
  ## intended for updating metrics, debug logging etc.
  ##
  discard

template runDaemon*(ctx: SnapCtxRef; info: static[string]): Duration =
  ## Async/template
  ##
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true` which corresponds to `ctx.hibernating` set
  ## to false.
  ##
  ## On a fresh start, the flag `ctx.daemon` will not be set `true` before the
  ## first usable request from the CL (via RPC) stumbles in.
  ##
  ## The template returns a suggested idle time for waiting after this task.
  ##
  var bodyRc = ZeroDuration                         # to be re-invoked, soon?
  block body:
    case ctx.updateSnapState(info):                 # set next state
    of SnapIdle:
      discard                                       # currently placeholder only

    of SnapResume:
      ctx.downloadResume(info).isOkOr:
        ctx.pool.resetReq = true                    # not much else possible
        break body
      discard ctx.downloadInit(info)                # init download if possible

    of SnapClear:
      # Clear cache DB if needed.
      let hasDataOrErr = ctx.pool.cacheDB.hasAccMissingIntv(info).valueOr: true
      if hasDataOrErr and not ctx.pool.cacheDB.clear(info):
        bodyRc = daemonWaitClearFailInterval        # take a nap
        break body

      doAssert ctx.resetServices(info).isOk         # reset system

    of SnapReady:
      # Start headers download on the beacon sync server to run
      # in quasi-parallel mode to the snap sync daemon & peers.
      ctx.headerDownloadTrigger(info).isOkOr:
        bodyRc = daemonWaitReadyDwnldFailInterval   # take a nap
        break body

      ctx.downloadInit(info).isOkOr:                # get ready
        bodyRc = daemonWaitReadyInitFailInterval    # take a nap

    of SnapDownload:
      # Download headers. The request will be silently ignored if the
      # distance to the CL head is too small.
      discard ctx.headerDownloadTrigger(info)
      bodyRc = daemonWaitDownloadInterval           # parallel peer action

    of SnapDownloadFinish:
      discard

    of SnapBalsFetch:
      discard ctx.headerDownloadTrigger(info)       # see `SnapDownload`
      bodyRc = daemonWaitBalsFetchInterval          # parallel peer action

    of SnapBalsFetchFinish:
      discard

    of SnapStateForward:
      ctx.stateForward(info).isOkOr:
        break body

      # Prepare for next download cyle
      discard ctx.downloadInit(info)                # get cache DB ready

      debug info & ": Forwarded state", pivotNum=ctx.pool.pivotNum,
        forwardNum=ctx.pool.forwardNum

    of SnapAssembleMpt:
      ctx.importCoreDb(info).isOkOr:
        ctx.pool.resetReq = true                    # not much else possible

    of SnapStop:
      ctx.accountDownloadMetricsReset()             # cosmetics

      # Done, terminate
      if 0 < ctx.pool.newCoreDb.newDbPath.len:
        if not ctx.pool.newCoreDb.waitSync:
          notice info & ": Snap sync successful, will terminate",
            dbPath=ctx.pool.newCoreDb.newDbPath
          ctx.pool.newCoreDb.waitSync = true
          ctx.headerDownloadCancel()
        elif ctx.beaconState == BeaconState.idle:
          ctx.daemon = false                        # all done, stop
          ctx.pool.newCoreDb.waitSync = false
          ctx.pool.newCoreDb.snapSyncStop = true
        else:
          ctx.pool.lastBcSyncLog.logCtrl(beaconSyncIdleLogWaitInterval):
            debug info & ": Waiting for beacon sync to terminate",
              beaconState=ctx.beaconState
          bodyRc = daemonWaitHeaderStopInterval     # wait for beacon sync
        break body

      # This should have been handled by the FSA update
      raiseAssert info & ": Snap sync is not ready yet to terminate"

    # End block: `body`

  bodyRc

proc runPool*(
    buddy: SnapPeerRef;
    last: bool;
    laps: int;
    info: static[string];
      ): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as long as this function returns `false`. There will be no other
  ## `runPeer()` functions activated while `runPool()` is active.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) The flag will be automatically reset before
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `laps` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## If there was no peer available when `buddy.ctx.poolMode` wass set, the
  ## scheduler will wait until at least one peer is running. Then the
  ## `runPool()` cycle will be executed (with the single peer.)
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let ctx = buddy.ctx

  case ctx.pool.syncState:
  of SnapDownloadFinish:
    ctx.downloadCommit(info).isOkOr:                # write back ranges to DB
      error info & ": Error storing progress", `error`=error
  else:
    discard

  ctx.statsStateLog info                            # print statistics
  true                                              # stop

template runPeer*(
    buddy: SnapPeerRef;
    info: static[string];
      ): Duration =
  ## Async/template
  ##
  ## This peer worker method is repeatedly invoked (exactly one per peer) while
  ## the `buddy.ctrl.poolMode` flag is set `false`.
  ##
  ## The template returns a suggested idle time for after this task.
  ##
  var bodyRc = ZeroDuration
  block body:
    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer            # logging only

    case ctx.pool.syncState:
    of SnapDownload:
      if buddy.isSuspendedDownload():
        bodyRc = peerWaitExhaustedInterval
        break body

      # Download and cache accounts, storage slots, contracts
      buddy.downloadState(info).isOkOr:
        if error == ENoDataAvailable:
          buddy.suspendDownload()
          debug info & ": State downloading stopped", peer,
            pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
            nSyncPeers=ctx.nSyncPeers(), `error`=error
        bodyRc = peerWaitDownloadInterval
        break body

      bodyRc = peerWaitDownloadInterval

    of SnapBalsFetch:
      # Prefer peers that support the snap/2 protocol
      if not buddy.only.supportsBal and
         buddy.snap2PeersAvailable():
        bodyRc = peerWaitBalsSnap1Interval
        break body
      buddy.downloadBals(info).isOkOr:
        if error == ELockError:
          bodyRc = peerWaitBalsLockedInterval
          break body

        if error == ENoDataAvailable or
           error == EAlreadyTriedAndFailed:
          if buddy.only.supportsBal:                # applies to snap/2 only
            buddy.suspendBal()
          bodyRc = peerWaitBalsNoDataInterval
          break body

        if error == EHeadersMissing:
          ctx.pool.lastNoHdrsLog.logCtrl(noHeadersLogWaitInterval):
            trace info & ": No BALs downloading, headers missing", peer,
              pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
              nSyncPeers=ctx.nSyncPeers()
          discard ctx.headerDownloadTrigger(info)
          bodyRc = peerWaitHeadersInterval
          break body

        if error == EMissingEthContext:
          ctx.pool.lastNoPeersLog.logCtrl(noPeersLogWaitInterval):
            trace info & ": No BALs supporting eth peers", peer,
              pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
              nSyncPeers=ctx.nSyncPeers()
          bodyRc = peerWaitNoEthPeersInterval
          break body

        trace info & ": BALs download error", peer,
          pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
          nSyncPeers=ctx.nSyncPeers(), `error`=error

    else:
      bodyRc = peerWaitElseInterval

    # End block: `body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
