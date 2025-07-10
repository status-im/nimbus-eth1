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

proc versionInfoWorker*(
    run: ReplayRunnerRef;
    instr: TraceVersionInfo;
    info: static[string];
      ) =
  let
    n = run.instrNumber
    ctx = run.ctx
  var
    versionOK = true

  if run.instrNumber != 1:
    error info & ": not the first record", n, expected=1
    versionOK = false

  if instr.version != TraceVersionID:
    error info & ": wrong version", n,
      traceLayoutVersion=instr.version, expected=TraceVersionID
    versionOK = false

  if instr.networkId != ctx.chain.com.networkId:
    error info & ": wrong network", n,
      networkId=instr.networkId, expected=ctx.chain.com.networkId
    versionOK = false

  if ctx.chain.baseNumber < instr.baseNum:
    error info & ": cannot start (base too low)", n,
      base=ctx.chain.baseNumber.bnStr, replayBase=instr.baseNum.bnStr
    versionOK = false

  if not ctx.hibernate:
    error info & ": syncer must not be activated, yet", n
    versionOK = false

  if not versionOK:
    run.stopError(info & ": version match failed")
    return

  trace "=Version", TraceVersionID, envID=instr.envID
  run.checkSyncerState(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
