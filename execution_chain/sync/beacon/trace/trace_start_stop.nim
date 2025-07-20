# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Trace environment setup & destroy

{.push raises:[].}

import
  std/streams,
  pkg/[chronicles, chronos],
  ./trace_start_stop/handlers/[blocks, headers, helpers, sched, sync],
  ./[trace_desc, trace_write]

logScope:
  topics = "beacon trace"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

  stopInfo = "traceStop(): "
  startInfo = "traceStart(): "

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template onException(
    info: static[string];
    quitCode: static[int];
    code: untyped) =
  try:
    code
  except CatchableError as e:
    const blurb = info & "Trace stream exception"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb & " -- STOP", error=($e.name), msg=e.msg
      quit(quitCode)

# -----------

proc traceStop(trc: TraceRef) =
  if not trc.isNil:
    trc.ctx.pool.handlers = trc.backup

    stopInfo.onException(DontQuit):
      trc.outStream.flush()
      trc.outStream.close()

proc stopIfEos(trc: TraceRef) =
  trc.remaining.dec
  if trc.remaining <= 0:
    info stopInfo & "Number of sessions exhausted", nSessions=trc.sessions
    trc.traceStop()

proc writeVersion(ctx: BeaconCtxRef) =
  var tRec: TraceVersionInfo
  tRec.init ctx
  tRec.version = TraceVersionID
  tRec.networkId = ctx.chain.com.networkId
  ctx.traceWrite tRec
  trace "=Version", TraceVersionID, serial=tRec.serial

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc traceStop*(ctx: BeaconCtxRef) =
  ctx.trace.traceStop()


proc traceStart*(ctx: BeaconCtxRef; strm: Stream; nSessions: int) =
  ## Start trace session
  let nSessions = min(1, nSessions)

  if ctx.handler.version in {0, TraceBaseHandlersID}:
    ctx.pool.handlers = TraceRef(

      # Install new Overlay handler descriptor
      ctx:             ctx,
      outStream:       strm,
      backup:          ctx.pool.handlers,
      started:         Moment.now(),
      sessions:        nSessions,
      remaining:       nSessions,
      stopIfEos:       stopIfEos,

      # Set up redirect handlers for tracing
      version:         TraceOverlayHandlersID,
      activate:        activateTrace,
      suspend:         suspendTrace,
      schedDaemon:     schedDaemonTrace,
      schedStart:      schedStartTrace,
      schedStop:       schedStopTrace,
      schedPool:       schedPoolTrace,
      schedPeer:       schedPeerTrace,
      getBlockHeaders: fetchHeadersTrace,
      getBlockBodies:  fetchBodiesTrace,
      importBlock:     importBlockTrace)

    # Write version as first record
    ctx.writeVersion()

  elif ctx.handler.version == TraceOverlayHandlersID:
    # Install new output file
    let trc = ctx.handler.TraceRef
    startInfo.onException(QuitFailure):
      trc.outStream.flush()
      trc.outStream.close()
    trc.outStream = strm
    trc.sessions = nSessions
    trc.remaining = nSessions

  else:
    fatal startInfo & "Overlay session handlers activated already",
      ID=ctx.handler.version
    quit(QuitFailure)


proc traceStart*(ctx: BeaconCtxRef) =
  ## Variant of `traceStart()` for pre-initialised handlers (see
  ## `traceSetup()`.)
  ##
  if ctx.handler.version == TraceBaseHandlersID:
    let hdl = ctx.handler.TraceBaseHandlersRef
    ctx.traceStart(hdl.strm, hdl.nSessions)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
