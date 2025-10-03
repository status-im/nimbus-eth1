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
  ./runner_desc,
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
  ## Execute the internal capture object argument `pyl` as an instruction.
  ##
  run.instrNumber.inc

  trace "+dispatch()", n=run.instrNumber, recType=pyl.recType,
    nBuddies=run.peers.len, nDaemons=(if run.daemon.isNil: 0 else: 1)

  case pyl.recType:
  of TraceRecType(0):
    warn "dispatch(): Oops, unexpected void record", n=run.instrNumber

  of VersionInfo:
    run.versionInfoWorker(pyl.ReplayVersionInfo)
    
  of SyncActvFailed:
    run.syncActvFailedWorker(pyl.ReplaySyncActvFailed)
  of SyncActivated:
    run.syncActivateWorker(pyl.ReplaySyncActivated)
  of SyncHibernated:
    run.syncSuspendWorker(pyl.ReplaySyncHibernated)

  # Simple scheduler single run (no begin/end) functions
  of SchedStart:
    run.schedStartWorker(pyl.ReplaySchedStart)
  of SchedStop:
    run.schedStopWorker(pyl.ReplaySchedStop)
  of SchedPool:
    run.schedPoolWorker(pyl.ReplaySchedPool)

  # Workers, complex run in background
  of SchedDaemonBegin:
    await run.schedDaemonBegin(pyl.ReplaySchedDaemonBegin)
  of SchedDaemonEnd:
    await run.schedDaemonEnd(pyl.ReplaySchedDaemonEnd)
  of SchedPeerBegin:
    await run.schedPeerBegin(pyl.ReplaySchedPeerBegin)
  of SchedPeerEnd:
    await run.schedPeerEnd(pyl.ReplaySchedPeerEnd)

  # Leaf handlers providing input data to background tasks `runDaemon()`
  # and/or `runPeer()`.
  of FetchHeaders:
    await run.sendHeaders(pyl.ReplayFetchHeaders)
  of SyncHeaders:
    await run.sendHeaders(pyl.ReplaySyncHeaders)

  of FetchBodies:
    await run.sendBodies(pyl.ReplayFetchBodies)
  of SyncBodies:
    await run.sendBodies(pyl.ReplaySyncBodies)

  of ImportBlock:
    await run.sendBlock(pyl.ReplayImportBlock)
  of SyncBlock:
    await run.sendBlock(pyl.ReplaySyncBlock)

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
