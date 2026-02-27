# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Overlay handler for trace environment

{.push raises:[].}

import
  pkg/chronicles,
  ../trace_desc,
  ./[setup_helpers, setup_write]

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc activateTrace*(ctx: BeaconCtxRef) =
  ## Replacement for `activate()` handler which in addition
  ## write data to the output stream for tracing.
  ##
  let hdl = ctx.trace.backup
  hdl.activate ctx

  if not ctx.hibernate:
    var tRec: TraceSyncActivated
    tRec.init ctx
    tRec.head = ctx.hdrCache.head
    tRec.finHash = ctx.chain.resolvedFinHash
    ctx.traceWrite tRec

    trace TraceTypeLabel[SyncActivated], serial=tRec.serial


proc suspendTrace*(ctx: BeaconCtxRef) =
  ## Replacement for `suspend()` handler which in addition writes
  ## data to the output stream for tracing.
  ##
  let hdl = ctx.trace.backup
  hdl.suspend ctx

  var tRec: TraceSyncHibernated
  tRec.init ctx
  ctx.traceWrite tRec

  trace TraceTypeLabel[SyncHibernated], serial=tRec.serial

  let trc = ctx.trace
  if not trc.isNil:
    trc.stopIfEos(trc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
