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
  std/tables,
  pkg/[chronicles, chronos, eth/common],
  ../../replay_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc schedDaemonProcessImpl(
    daemon: ReplayDaemonRef;
    instr: TraceSchedDaemonBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedDaemon()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let run = daemon.run
  trace info & ": begin", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, syncState=instr.syncState

  discard await run.worker.schedDaemon(run.ctx)
  daemon.processFinished(instr, info)

  trace info & ": end", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, syncState=instr.syncState


proc schedPeerProcessImpl(
    buddy: ReplayBuddyRef;
    instr: TraceSchedPeerBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedPeer()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let run = buddy.run
  trace info & ": begin", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short,
    syncState=instr.syncState

  # Activate peer
  buddy.run.nPeers.inc

  discard await run.worker.schedPeer(buddy)
  buddy.processFinished(instr, info)

  trace info & ": end", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short,
    syncState=instr.syncState

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc schedDaemonBegin*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the `schedDaemon()` task.
  ##
  # Synchronise against captured environment and start process
  let daemon = run.newDaemonFrame(instr, info).valueOr: return
  discard await daemon.waitForSyncedEnv(instr, info)
  asyncSpawn daemon.schedDaemonProcessImpl(instr, info)


proc schedDaemonEnd*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonEnd;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedDaemon()` process has terminated.
  ##
  let daemon = run.getDaemon(info).valueOr: return
  daemon.whenProcessFinished(instr, info).isErrOr:
    daemon.delDaemon(info) # Clean up


proc schedStartWorker*(
    run: ReplayRunnerRef;
    instr: TraceSchedStart;
    info: static[string];
      ) =
  ## Runs `schedStart()` in the foreground.
  ##
  let
    buddy = run.newPeer(instr, info)
    accept = run.worker.schedStart(buddy)

  trace info & ": begin", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short

  if accept != instr.accept:
    warn info & ": result argument differs", n=run.iNum, serial=instr.serial,
      peer=buddy.peer, expected=instr.accept, result=accept

  # Syncer state was captured when leaving the `schedStart()` handler.
  buddy.checkSyncerState(instr, ignLatestNum=true, info) # relaxed check

  if not accept:
    buddy.delPeer(info) # Clean up

  trace info & ": end", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short


proc schedStopWorker*(
    run: ReplayRunnerRef;
    instr: TraceSchedStop;
    info: static[string];
      ) =
  ## Runs `schedStop()` in the foreground.
  ##
  let buddy = run.getOrNewPeerFrame(instr, info)
  run.worker.schedStop(buddy)

  # As the `schedStop()` function environment was captured only after the
  # syncer was activated, there might still be some unregistered peers hanging
  # around. So it is perfectly OK to see the peer for the first time, here
  # which has its desciptor sort of unintialised (relative to `instr`.)
  if not buddy.isNew:
    # Syncer state was captured when leaving the `schedStop()` handler.
    if instr.peerCtrl == Stopped and not buddy.ctrl.stopped:
      buddy.ctrl.stopped = true
    buddy.checkSyncerState(instr, info)

  # Clean up
  buddy.delPeer(info)

  trace info & ": done", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short


proc schedPoolWorker*(
    run: ReplayRunnerRef;
    instr: TraceSchedPool;
    info: static[string];
      ) =
  ## Runs `schedPool()` in the foreground.
  ##
  let buddy = run.getOrNewPeerFrame(instr, info)

  if 0 < run.nPeers:
    warn info & ": no active peers allowed", n=run.iNum, serial=instr.serial,
      peer=buddy.peer, nPeers=run.nPeers, expected=0

  # The scheduler will reset the `poolMode` flag before starting the
  # `schedPool()` function.
  run.ctx.poolMode = false

  discard run.worker.schedPool(buddy, instr.last, instr.laps.int)

  # Syncer state was captured when leaving the `schedPool()` handler.
  buddy.checkSyncerState(instr, info)

  # Reset frame data
  buddy.frameID = 0

  info info & ": done", n=run.iNum, serial=instr.serial,
    frameID=instr.frameID.idStr, peer=($buddy.peer), peerID=buddy.peerID.short


proc schedPeerBegin*(
    run: ReplayRunnerRef;
    instr: TraceSchedPeerBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the `schedPeer()` task.
  ##
  # Synchronise against captured environment and start process
  let buddy = run.getOrNewPeerFrame(instr, info)
  discard await buddy.waitForSyncedEnv(instr, info)
  asyncSpawn buddy.schedPeerProcessImpl(instr, info)


proc schedPeerEnd*(
    run: ReplayRunnerRef;
    instr: TraceSchedPeerEnd;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedPeer()` process has terminated.
  ##
  let buddy = run.getPeer(instr, info).valueOr: return
  buddy.whenProcessFinished(instr, info).isErrOr:
    buddy.run.nPeers.dec # peer is not active, anymore

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
