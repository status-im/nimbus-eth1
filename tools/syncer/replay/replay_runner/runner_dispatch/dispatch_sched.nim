# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  ../runner_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc schedDaemonProcessImpl(
    daemon: ReplayDaemonRef;
    instr: ReplaySchedDaemonBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedDaemon()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let run = daemon.run
  trace info & ": begin", n=run.iNum, serial=instr.bag.serial,
    frameID=instr.frameIdStr, syncState=instr.bag.syncState

  discard await run.backup.schedDaemon(run.ctx)
  daemon.processFinishedClearFrame(instr, info)

  trace info & ": end", n=run.iNum, serial=instr.bag.serial,
    frameID=instr.frameIdStr, syncState=instr.bag.syncState


proc schedPeerProcessImpl(
    buddy: ReplayPeerRef;
    instr: ReplaySchedPeerBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedPeer()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let run = buddy.run
  trace info & ": begin", n=run.iNum, serial=instr.bag.serial,
    frameID=instr.frameIdStr, peer=($buddy.peer), peerID=buddy.peerID.short,
    syncState=instr.bag.syncState

  discard await run.backup.schedPeer(buddy, instr.bag.rank)
  buddy.processFinishedClearFrame(instr, info)

  trace info & ": end", n=run.iNum, serial=instr.bag.serial,
    frameID=instr.frameIdStr, peer=($buddy.peer), peerID=buddy.peerID.short,
    syncState=instr.bag.syncState

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc schedDaemonBegin*(
    run: ReplayRunnerRef;
    instr: ReplaySchedDaemonBegin;
      ) {.async: (raises: []).} =
  ## Run the `schedDaemon()` task.
  ##
  # Synchronise against captured environment and start process
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let daemon = run.newDaemonFrame(instr, info).valueOr: return
  discard await daemon.waitForSyncedEnv(instr, info)
  asyncSpawn daemon.schedDaemonProcessImpl(instr, info)


proc schedDaemonEnd*(
    run: ReplayRunnerRef;
    instr: ReplaySchedDaemonEnd;
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedDaemon()` process has terminated.
  ##
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let daemon = run.getDaemon(info).valueOr: return
  daemon.whenProcessFinished(instr, info).isErrOr:
    daemon.delDaemon(info) # Clean up


proc schedStartWorker*(
    run: ReplayRunnerRef;
    instr: ReplaySchedStart;
      ) =
  ## Runs `schedStart()` in the foreground.
  ##
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let
    buddy = run.newPeer(instr, info).valueOr: return
    accept = run.backup.schedStart(buddy)

  trace info & ": begin", n=run.iNum, serial=instr.bag.serial,
    peer=($buddy.peer), peerID=buddy.peerID.short

  if accept != instr.bag.accept:
    warn info & ": result argument differs", n=run.iNum,
      serial=instr.bag.serial, peer=buddy.peer, expected=instr.bag.accept,
      result=accept

  # Syncer state was captured when leaving the `schedStart()` handler.
  buddy.checkSyncerState(instr, ignLatestNum=true, info) # relaxed check

  if not accept:
    buddy.delPeer(info) # Clean up

  trace info & ": end", n=run.iNum, serial=instr.bag.serial,
    peer=($buddy.peer), peerID=buddy.peerID.short


proc schedStopWorker*(
    run: ReplayRunnerRef;
    instr: ReplaySchedStop;
      ) =
  ## Runs `schedStop()` in the foreground.
  ##
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let buddy = run.getOrNewPeerFrame(instr, info).valueOr: return
  run.backup.schedStop(buddy)

  # As the `schedStop()` function environment was captured only after the
  # syncer was activated, there might still be some unregistered peers hanging
  # around. So it is perfectly OK to see the peer for the first time, here
  # which has its desciptor sort of unintialised (relative to `instr`.)
  if not buddy.isNew:
    # Syncer state was captured when leaving the `schedStop()` handler.
    if instr.bag.peerCtx.isNone():
      warn info & ": peer ctx missing", n=run.iNum, serial=instr.bag.serial
      return
    if instr.bag.peerCtx.value.peerCtrl == Stopped and not buddy.ctrl.stopped:
      buddy.ctrl.stopped = true
    buddy.checkSyncerState(instr, rlxBaseNum=false, ignLatestNum=true, info)

  # Clean up
  buddy.delPeer(info)

  trace info & ": done", n=run.iNum, serial=instr.bag.serial,
    peer=($buddy.peer), peerID=buddy.peerID.short


proc schedPoolWorker*(
    run: ReplayRunnerRef;
    instr: ReplaySchedPool;
      ) =
  ## Runs `schedPool()` in the foreground.
  ##
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let buddy = run.getOrNewPeerFrame(instr, info).valueOr: return

  # The scheduler will reset the `poolMode` flag before starting the
  # `schedPool()` function.
  run.ctx.poolMode = false

  discard run.backup.schedPool(buddy, instr.bag.last, instr.bag.laps.int)

  # Syncer state was captured when leaving the `schedPool()` handler.
  buddy.checkSyncerState(instr, info)
  buddy.processFinishedClearFrame(instr, info)

  info info & ": done", n=run.iNum, serial=instr.bag.serial,
    peer=($buddy.peer), peerID=buddy.peerID.short


proc schedPeerBegin*(
    run: ReplayRunnerRef;
    instr: ReplaySchedPeerBegin;
      ) {.async: (raises: []).} =
  ## Run the `schedPeer()` task.
  ##
  # Synchronise against captured environment and start process
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let buddy = run.getOrNewPeerFrame(instr, info).valueOr: return
  discard await buddy.waitForSyncedEnv(instr, info)
  asyncSpawn buddy.schedPeerProcessImpl(instr, info)


proc schedPeerEnd*(
    run: ReplayRunnerRef;
    instr: ReplaySchedPeerEnd;
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedPeer()` process has terminated.
  ##
  const info = instr.replayLabel()
  run.nSyncPeers = instr.bag.nSyncPeers.int

  let buddy = run.getPeer(instr, info).valueOr: return
  discard buddy.whenProcessFinished(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
