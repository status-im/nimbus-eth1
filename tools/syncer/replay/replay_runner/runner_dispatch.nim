# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  ../../../../execution_chain/networking/p2p,
  ../replay_desc,
  ./runner_dispatch/[dispatch_blocks, dispatch_headers, dispatch_sched,
                     dispatch_sync, dispatch_version]

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc dispatch*(
    run: ReplayRunnerRef;
    pyl: ReplayPayloadRef;
      ) {.async: (raises: []).} =
  ## Execure next instruction
  ##
  run.instrNumber.inc

  trace "+dispatch()", n=run.instrNumber, recType=pyl.recType,
    nBuddies=run.peers.len, nDaemons=(if run.daemon.isNil: 0 else: 1)

  case pyl.recType:
  of TrtOops:
    warn "dispatch(): Oops, unexpected void record", n=run.instrNumber

  of TrtVersionInfo:
    run.versionInfoWorker(pyl.ReplayVersionInfo.data, "=Version")
    
  of TrtSyncActvFailed:
    run.syncActvFailedWorker(pyl.ReplaySyncActvFailed.data, "=ActvFailed")
  of TrtSyncActivated:
    run.syncActivateWorker(pyl.ReplaySyncActivated.data, "=Activated")
  of TrtSyncHibernated:
    run.syncSuspendWorker(pyl.ReplaySyncHibernated.data, "=Suspended")

  # Simple scheduler single run (no begin/end) functions
  of TrtSchedStart:
    run.schedStartWorker(pyl.ReplaySchedStart.data, "=StartPeer")
  of TrtSchedStop:
    run.schedStopWorker(pyl.ReplaySchedStop.data, "=StopPeer")
  of TrtSchedPool:
    run.schedPoolWorker(pyl.ReplaySchedPool.data, "=Pool")

  # Workers, complex run in background
  of TrtSchedDaemonBegin:
    await run.schedDaemonBegin(pyl.ReplaySchedDaemonBegin.data, "+Daemon")
  of TrtSchedDaemonEnd:
    await run.schedDaemonEnd(pyl.ReplaySchedDaemonEnd.data, "-Daemon")
  of TrtSchedPeerBegin:
    await run.schedPeerBegin(pyl.ReplaySchedPeerBegin.data, "+Peer")
  of TrtSchedPeerEnd:
    await run.schedPeerEnd(pyl.ReplaySchedPeerEnd.data, "-Peer")

  # Leaf handlers providing input data to background tasks `runDaemon()`
  # and/or `runPeer()`.
  of TrtFetchHeaders:
    await run.sendHeaders(pyl.ReplayFetchHeaders.data, "=HeadersFetch")
  of TrtSyncHeaders:
    await run.sendHeaders(pyl.ReplaySyncHeaders.data, "=HeadersSync")

  of TrtFetchBodies:
    await run.sendBodies(pyl.ReplayFetchBodies.data, "=BodiesFetch")
  of TrtSyncBodies:
    await run.sendBodies(pyl.ReplaySyncBodies.data, "=BodiesSync")

  of TrtImportBlock:
    await run.sendBlock(pyl.ReplayImportBlock.data, "=BlockImport")
  of TrtSyncBlock:
    await run.sendBlock(pyl.ReplaySyncBlock.data, "=BlockSync")

  trace "-dispatch()", n=run.instrNumber, recType=pyl.recType,
    nBuddies=run.peers.len, nDaemons=(if run.daemon.isNil: 0 else: 1)


proc dispatchEnd*(
    run: ReplayRunnerRef;
      ) {.async: (raises: []).} =
  # Finish
  run.instrNumber.inc
  info "End replay", n=run.instrNumber

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
