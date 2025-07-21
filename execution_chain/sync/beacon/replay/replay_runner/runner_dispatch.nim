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
  ../../../../networking/p2p,
  ../replay_desc,
  ./runner_dispatch/[dispatch_blocks, dispatch_headers, dispatch_sched,
                     dispatch_sync, dispatch_version]

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

const minLineNr = 0 # 210

proc dispatch*(
    run: ReplayRunnerRef;
    pyl: ReplayPayloadRef;
      ) {.async: (raises: []).} =
  ## Execure next instruction
  ##
  run.instrNumber.inc

  if minLineNr <= run.instrNumber:
    trace "dispatch(): begin", n=run.instrNumber, recType=pyl.recType,
      nBuddies=run.peers.len, nDaemons=(if run.daemon.isNil: 0 else: 1)

  case pyl.recType:
  of TrtOops:
    warn "dispatch(): Oops, unexpected void record", n=run.instrNumber

  of TrtVersionInfo:
    run.versionInfoWorker(
      pyl.ReplayVersionInfo.data, "=Version")
    
  of TrtSyncActvFailed:
    run.syncActvFailedWorker(
      pyl.ReplaySyncActvFailed.data, "=ActvFailed")
  of TrtSyncActivated:
    run.syncActivateWorker(
      pyl.ReplaySyncActivated.data, "=Activated")
  of TrtSyncHibernated:
    run.syncSuspendWorker(
      pyl.ReplaySyncHibernated.data, "=Suspended")

  of TrtSchedDaemonBegin:
    await run.schedDaemonProcess(
      pyl.ReplaySchedDaemonBegin.data, "+Daemon: ")
  of TrtSchedDaemonEnd:
    await run.schedDaemonCleanUp(
      pyl.ReplaySchedDaemonEnd.data, "-Daemon: ")

  of TrtSchedPeerBegin:
    await run.schedPeerProcess(
      pyl.ReplaySchedPeerBegin.data, "+Peer: ")
  of TrtSchedPeerEnd:
    await run.schedPeerCleanUp(
      pyl.ReplaySchedPeerEnd.data, "-Peer: ")

  # Provide input data to background tasks `runDaemon()` and/or `runPeer()`
  of TrtGetBlockHeaders:
    await run.fetchHeadersFeed(
      pyl.ReplayGetBlockHeaders.data, "=HeadersFetch: ")
  of TrtGetBlockBodies:
    await run.fetchBodiesFeed(
      pyl.ReplayGetBlockBodies.data, "=FetchBodies: ")
  of TrtImportBlock:
    await run.importBlockFeed(
      pyl.ReplayImportBlock.data, "=ImportBlock: ")

  # Simple scheduler single run (no begin/end) functions
  of TrtSchedStart:
    run.schedStartWorker(
      pyl.ReplaySchedStart.data, "=StartPeer: ")
  of TrtSchedStop:
    run.schedStopWorker(
      pyl.ReplaySchedStop.data, "=StopPeer: ")
  of TrtSchedPool:
    run.schedPoolWorker(
      pyl.ReplaySchedPool.data, "=Pool: ")

  if minLineNr <= run.instrNumber:
    trace "dispatch(): end", n=run.instrNumber, recType=pyl.recType,
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
