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
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc schedDaemonProcess*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedDaemon()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let daemon = run.newDaemonFrame(instr, info).valueOr: return
  info info & "begin", serial=instr.serial, syncState=instr.syncState

  # Synchronise against captured environment
  (await daemon.waitForSyncedEnv(instr, info)).isOkOr: return

  await run.worker.schedDaemon(run.ctx)
  daemon.processFinished(instr, info)


proc schedDaemonCleanUp*(
    run: ReplayRunnerRef;
    instr: TraceSchedDaemonEnd;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedDaemon()` process has terminated.
  ##
  let daemon = run.getDaemon(info).valueOr: return

  # Wait for daemon to terminate
  (await daemon.waitForProcessFinished(instr, info)).isOkOr: return

  # Clean up
  daemon.delDaemon(info)

  info info & "done", serial=instr.serial, syncState=instr.syncState


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

  if accept != instr.accept:
    warn info & "result argument differs", serial=instr.serial,
      peer=buddy.peer, expected=instr.accept, result=accept

  # Syncer state was captured when leaving the `schedStart()` handler.
  buddy.checkSyncerState(instr, info)

  if not accept:
    buddy.delPeer(info) # Clean up

  info info & "done", serial=instr.serial, peer=($buddy.peer),
    peerID=buddy.peerID.short


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
    buddy.checkSyncerState(instr, info)

  # Clean up
  buddy.delPeer(info)
  
  info info & "done", serial=instr.serial, peer=($buddy.peer),
    peerID=buddy.peerID.short


proc schedPoolWorker*(
    run: ReplayRunnerRef;
    instr: TraceSchedPool;
    info: static[string];
      ) =
  ## Runs `schedPool()` in the foreground.
  ##
  let buddy = run.getOrNewPeerFrame(instr, info)

  if 0 < run.nPeers:
    warn info & "no active peers allowed", serial=instr.serial,
      peer=buddy.peer, nPeers=run.nPeers, expected=0

  # The scheduler will reset the `poolMode` flag before starting the
  # `schedPool()` function.
  run.ctx.poolMode = false

  discard run.worker.schedPool(buddy, instr.last, instr.laps.int)

  # Syncer state was captured when leaving the `schedPool()` handler.
  buddy.checkSyncerState(instr, info)

  # Pop frame data from `stage[]` stack
  buddy.stage.setLen(0)

  info info & "done", serial=instr.serial, peer=($buddy.peer),
    peerID=buddy.peerID.short


proc schedPeerProcess*(
    run: ReplayRunnerRef;
    instr: TraceSchedPeerBegin;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Run the task `schedPeer()`. This function has to be run background
  ## process (using `asyncSpawn`.)
  ##
  let buddy = run.getOrNewPeerFrame(instr, info)
  info info & "begin", serial=instr.serial, peer=($buddy.peer),
    peerID=buddy.peerID.short, syncState=instr.syncState

  # Synchronise against captured environment
  (await buddy.waitForSyncedEnv(instr, info)).isOkOr: return

  # Activate peer
  buddy.run.nPeers.inc
  await run.worker.schedPeer(buddy)

  # This peer job has completed
  buddy.processFinished(instr, info)


proc schedPeerCleanUp*(
    run: ReplayRunnerRef;
    instr: TraceSchedPeerEnd;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Clean up (in foreground) after `schedPeer()` process has terminated.
  ##
  let buddy = run.getPeer(instr, info).valueOr: return

  # Peer is not active, anymore
  buddy.run.nPeers.dec

  # Wait for peer to terminate
  (await buddy.waitForProcessFinished(instr, info)).isOkOr: return
  
  info info & "done", serial=instr.serial, peer=($buddy.peer),
    peerID=buddy.peerID.short, syncState=instr.syncState

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
