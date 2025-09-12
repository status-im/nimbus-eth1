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
  ../../../../../execution_chain/core/chain,
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
      ) =
  const info = instr.replayLabel()
  trace info, n=run.iNum, serial=instr.serial


proc syncActivateWorker*(
    run: ReplayRunnerRef;
    instr: TraceSyncActivated;
      ) =
  const
    info = instr.replayLabel()
  let
    serial = instr.serial
    ctx = run.ctx

  if not ctx.hibernate:
    warn info & ": already activated", n=run.iNum, serial
    return

  var activationOK = true
  if ctx.chain.baseNumber != instr.baseNum:
    error info & ": cannot activate (bases must match)", n=run.iNum, serial,
      base=ctx.chain.baseNumber.bnStr, expected=instr.baseNum.bnStr
    activationOK = false

  if activationOK:
    ctx.hdrCache.headTargetUpdate(instr.head, instr.finHash)

  # Set the number of active buddies (avoids some moaning.)
  run.ctx.pool.nBuddies = instr.nPeers.int
  run.checkSyncerState(instr, info)

  if ctx.hibernate or not activationOK:
    const failedInfo = info & ": activation failed"
    trace failedInfo, n=run.iNum, serial
    run.stopError(failedInfo)
  else:
    # No need for scheduler noise (e.g. disconnect messages.)
    ctx.noisyLog = false
    debug info, n=run.iNum, serial


proc syncSuspendWorker*(
    run: ReplayRunnerRef;
    instr: TraceSyncHibernated;
      ) =
  const info = instr.replayLabel()
  if not run.ctx.hibernate:
    run.stopError(info & ": suspend failed")
    return

  run.checkSyncerState(instr, info)
  debug info, n=run.iNum, serial=instr.serial

  # Shutdown if there are no remaining sessions left
  if 1 < run.nSessions:
    run.nSessions.dec
  else:
    run.stopOk(info & ": session(s) terminated")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
