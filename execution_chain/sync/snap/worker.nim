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
  pkg/[chronicles, chronos, minilru, results, stew/byteutils],
  ./worker/[download, helpers, cache_db, state_forward,
            start_stop, update, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc suspend(buddy: SnapPeerRef) =
  buddy.only.stateExhausted = buddy.ctx.pool.pivotNum

func isSuspended(buddy: SnapPeerRef): bool =
  buddy.ctx.pool.pivotNum <= buddy.only.stateExhausted

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

  if SnapReady < ctx.pool.syncState:
    debug info & ": New peer", peer, nSyncPeers=ctx.nSyncPeers(),
      peerType=buddy.only.peerType, clientId=buddy.peer.clientId
  true

proc stop*(buddy: SnapPeerRef; info: static[string]) =
  ## Clean up this peer
  let ctx = buddy.ctx
  if SnapReady < ctx.pool.syncState:
    debug info & ": Release peer", peer=buddy.peer,
      nSyncPeers=(ctx.nSyncPeers()-1), syncState=($buddy.syncState)
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
      discard

    of SnapResume:
      ctx.downloadInit(info).isOkOr:                # get cache DB ready
        bodyRc = daemonWaitResumeInterval           # not yet? take a nap

    of SnapClear:
      # Clear cache DB if needed.
      let hasData = ctx.pool.cacheDB.hasAccMissingIntv(info).valueOr: false
      if hasData and not ctx.pool.cacheDB.clear(info):
        bodyRc = daemonWaitClearInterval            # disk full?, failure
        break body

      # Start headers download on the beacon sync server to run
      # in quasi-parallel mode to the snap sync daemon & peers.
      ctx.headerDownloadTrigger(info).isOkOr:
        bodyRc = daemonWaitClearInterval            # take a nap

    of SnapReady:
      # Re-trigger headers fetch. This is effective only if the last attempt
      # was unsuccessful (maybe due to missing FC updates.)
      ctx.headerDownloadTrigger(info).isOkOr:
        bodyRc = daemonWaitClearInterval            # take a nap

      if ctx.pool.headersSynced:
        ctx.downloadInit(info).isOkOr:              # get ready
          bodyRc = daemonWaitReadyInterval          # take a nap

    of SnapDownload:
      # Download headers. The request will be silently ignored if the
      # distance to the CL head is too small.
      discard ctx.headerDownloadTrigger(info)
      bodyRc = daemonWaitDownloadInterval           # parallel peer action

    of SnapDownloadFinish:
      bodyRc = daemonWaitDownloadFinishInterval     # wait for sync

    of SnapBalsFetch:
      bodyRc = daemonWaitElseInterval               # parallel peer action

    of SnapBalsFetchFinish:
      bodyRc = daemonWaitElseInterval               # wait for sync

    of SnapStateForward:
      ctx.stateForward(info).isOkOr:
        break body

      # Prepare for next download cyle
      discard ctx.downloadInit(info)                # get cache DB ready

      debug info & ": Forwarded state", pivotNum=ctx.pool.pivotNum,
        forwardNum=ctx.pool.forwardNum

    # of TBD ..

    of SnapStop:
      warn info & ": Stop snap sync not implemented yet, lingering",
        syncState=($ctx.syncState)
      bodyRc = chronos.seconds(30)

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

  if ctx.pool.syncState == SnapDownloadFinish:
    ctx.downloadCommit(info).isOkOr:                # write back ranges to DB
      error info & ": Error storing progress", `error`=error

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
      if buddy.isSuspended():
        #trace info & ": Suspended on current state", peer,
        #  pivot=ctx.pool.pivotNum
        bodyRc = peerWaitExhaustedInterval
        break body

      # Download and cache accounts, storage slots, contracts
      buddy.downloadState(info).isOkOr:
        if error == ENoDataAvailable:
          buddy.suspend()
          debug info & ": Peer stopped downloading", peer,
            pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
            nSyncPeers=ctx.nSyncPeers(), `error`=error
        bodyRc = peerWaitDownloadInterval
        break body

      bodyRc = peerWaitDownloadInterval

    of SnapBalsFetch:
      buddy.downloadBals(info).isOkOr:
        if error == ELockError:
          let now = Moment.now                      # reduce logging noise
          if ctx.pool.lockedBalsLog + lockedBalsLogWaitInterval < now:
            ctx.pool.lockedBalsLog = now
            trace info & ": BALs downloading locked", peer,
              pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
              nSyncPeers=ctx.nSyncPeers()
          bodyRc = peerWaitBalsLockedInterval
          break body

        if error == EHeadersMissing:
          let now = Moment.now                      # reduce logging noise
          if ctx.pool.lastNoHdrsLog + noHeadersLogWaitInterval < now:
            ctx.pool.lastNoHdrsLog = now
            trace info & ": No BALs downloading, headers missing", peer,
              pivot=ctx.pool.pivotNum, syncState=($buddy.syncState),
              nSyncPeers=ctx.nSyncPeers()
          discard ctx.headerDownloadTrigger(info)
          bodyRc = peerWaitHeadersInterval
          break body

        if error == EMissingEthContext:
          let now = Moment.now                      # reduce logging noise
          if ctx.pool.lastNoPeersLog + noPeersLogWaitInterval < now:
            ctx.pool.lastNoPeersLog = now
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
