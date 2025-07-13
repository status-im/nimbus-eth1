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
  pkg/chronicles,
  ../../../../../core/chain,
  ../../replay_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc syncActvFailedWorker*(
    run: ReplayRunnerRef;
    instr: TraceSyncActvFailed;
    info: static[string];
      ) =
  trace info, serial=instr.serial


proc syncActivateWorker*(
    run: ReplayRunnerRef;
    instr: TraceSyncActivated;
    info: static[string]) =
  let
    serial = instr.serial
    envID = instr.envID.idStr
    ctx = run.ctx

  if not ctx.hibernate:
    warn info & ": already activated", serial
    return

  var activationOK = true
  if ctx.chain.baseNumber != instr.baseNum:
    error info & ": cannot activate (bases must match)", serial, envID,
      base=ctx.chain.baseNumber.bnStr, expected=instr.baseNum.bnStr
    activationOK = false

  if activationOK:
    ctx.hdrCache.headTargetUpdate(instr.head, instr.finHash)

  # Set the number of active buddies (avoids some moaning.)
  run.ctx.pool.nBuddies = instr.nPeers
  run.checkSyncerState(instr, info)

  if ctx.hibernate or not activationOK:
    trace "=ActvFailed", serial, envID
    run.stopError(instr, info & ": activation failed")
  else:
    # No need for scheduler noise (e.g. disconnect messages.)
    ctx.noisyLog = false
    trace "=Activated", serial, envID


proc syncSuspendWorker*(
    run: ReplayRunnerRef;
    instr: TraceSyncHibernated;
    info: static[string];
      ) =
  let ctx = run.ctx
  if ctx.hibernate:
    run.stopError(instr, info & ": suspend failed")
    return

  run.checkSyncerState(instr, info)
  trace "=Suspended", serial=instr.serial, envID=instr.envID.idStr

  # Shutdown if there are no remaining sessions left
  if 1 < run.nSessions:
    run.nSessions.dec
  else:
    run.stopOk(instr, info & ": session(s) terminated")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
