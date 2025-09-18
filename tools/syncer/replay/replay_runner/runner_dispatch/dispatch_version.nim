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
  ../runner_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc versionInfoWorker*(
    run: ReplayRunnerRef;
    instr: TraceVersionInfo;
      ) =
  const
    info = instr.replayLabel()
  let
    serial = instr.serial
    ctx = run.ctx
  var
    versionOK = true

  if serial != 1:
    error info & ": not the first record", serial, expected=1
    versionOK = false

  if run.instrNumber != 1:
    error info & ": record count mismatch", n=run.instrNumber, expected=1
    versionOK = false

  if instr.version != TraceVersionID:
    error info & ": wrong version", serial,
      traceLayoutVersion=instr.version, expected=TraceVersionID
    versionOK = false

  if instr.networkId != ctx.chain.com.networkId:
    error info & ": wrong network", serial,
      networkId=instr.networkId, expected=ctx.chain.com.networkId
    versionOK = false

  if ctx.chain.baseNumber < instr.baseNum:
    error info & ": cannot start (base too low)", serial,
      base=ctx.chain.baseNumber.bnStr, replayBase=instr.baseNum.bnStr
    versionOK = false

  if not ctx.hibernate:
    error info & ": syncer must not be activated, yet", serial
    versionOK = false

  if not versionOK:
    run.stopError(info & ": version match failed")
    return

  chronicles.info info, n=run.iNum, serial, TraceVersionID,
    base=ctx.chain.baseNumber.bnStr, latest=ctx.chain.latestNumber.bnStr
  run.checkSyncerState(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
