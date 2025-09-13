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
  std/[os, streams, syncio],
  pkg/[chronicles, chronos],
  ./trace_setup/[
    setup_blocks, setup_headers, setup_helpers, setup_sched, setup_sync,
    setup_write],
  ./trace_desc

logScope:
  topics = "beacon trace"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

  stopInfo = "traceStop(): "

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

proc stopIfEos(trc: TraceRef) =
  trc.remaining.dec
  if trc.remaining <= 0:
    info stopInfo & "Number of sessions exhausted", nSessions=trc.sessions
    trc.stopSync(trc)

proc writeVersion(ctx: BeaconCtxRef) =
  var tRec: TraceVersionInfo
  tRec.init ctx
  tRec.version = TraceVersionID
  tRec.networkId = ctx.chain.com.networkId
  ctx.traceWrite tRec
  trace "=Version", TraceVersionID, serial=tRec.serial

# -----------

proc traceStartCB(trc: TraceRef) =
  ## Start trace session handler
  ##
  trc.started =          Moment.now()
  trc.stopIfEos =        stopIfEos

  # Set up redirect handlers for trace/capture
  trc.version =          TraceRunnerID
  trc.activate =         activateTrace
  trc.suspend =          suspendTrace
  trc.schedDaemon =      schedDaemonTrace
  trc.schedStart =       schedStartTrace
  trc.schedStop =        schedStopTrace
  trc.schedPool =        schedPoolTrace
  trc.schedPeer =        schedPeerTrace
  trc.getBlockHeaders =  fetchHeadersTrace
  trc.syncBlockHeaders = syncHeadersTrace
  trc.getBlockBodies =   fetchBodiesTrace
  trc.syncBlockBodies =  syncBodiesTrace
  trc.importBlock =      importBlockTrace
  trc.syncImportBlock =  syncBlockTrace

  trc.startSync = proc(self: BeaconHandlersSyncRef) =
    discard

  trc.stopSync = proc(self: BeaconHandlersSyncRef) =
    stopInfo.onException(DontQuit):
      TraceRef(self).outStream.flush()
      TraceRef(self).outStream.close()
    TraceRef(self).ctx.pool.handlers = TraceRef(self).backup

  # Write version as first record
  trc.ctx.writeVersion()

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc traceSetup*(
    ctx: BeaconCtxRef;
    fileName: string;
    nSessions: int;
      ): Result[void,string] =
  ## Install trace handlers
  const info = "traceSetup(): "

  if ctx.handler.version != 0:
    return err("Overlay session handlers activated already" &
               ", ID=" & $ctx.handler.version)

  if fileName.fileExists: # File must not exist yet
    return err("Unsafe, please delete file first" &
               ", fileName=\"" & fileName & "\"")

  var strm = Stream(nil)
  info.onException(DontQuit):
    # Note that there is a race condition. The proper open mode shoud be
    # `fmReadWriteExisting` (sort of resembling `O_CREATE|O_EXCL`) but it
    # does not work with the current nim version `2.2.4`.
    var fd: File
    if fd.open(fileName, fmWrite):
      strm = fd.newFileStream()

  if strm.isNil:
    return err("Cannot open trace file for writing" &
               ", fileName=\"" & fileName & "\"")

  let trc = TraceRef(
    # Install new extended handler descriptor
    ctx:              ctx,
    outStream:        strm,
    backup:           ctx.pool.handlers,
    sessions:         nSessions,
    remaining:        nSessions,

    # This is still the old descriptor which will be updated when
    # `startSync()` is run.
    version:          TraceSetupID,
    activate:         ctx.handler.activate,
    suspend:          ctx.handler.suspend,
    schedDaemon:      ctx.handler.schedDaemon,
    schedStart:       ctx.handler.schedStart,
    schedStop:        ctx.handler.schedStop,
    schedPool:        ctx.handler.schedPool,
    schedPeer:        ctx.handler.schedPeer,
    getBlockHeaders:  ctx.handler.getBlockHeaders,
    syncBlockHeaders: ctx.handler.syncBlockHeaders,
    getBlockBodies:   ctx.handler.getBlockBodies,
    syncBlockBodies:  ctx.handler.syncBlockBodies,
    importBlock:      ctx.handler.importBlock,
    syncImportBlock:  ctx.handler.syncImportBlock)

  trc.startSync = proc(self: BeaconHandlersSyncRef) =
    TraceRef(self).traceStartCB()

  trc.stopSync = proc(self: BeaconHandlersSyncRef) =
    info.onException(DontQuit):
      TraceRef(self).outStream.close()
    TraceRef(self).ctx.pool.handlers = TraceRef(self).backup

  ctx.pool.handlers = trc
  ok()


proc traceRelease*(ctx: BeaconCtxRef) =
  ## Stop tracer and restore descriptors
  if ctx.pool.handlers.version in {TraceSetupID, TraceRunnerID}:
    TraceRef(ctx.pool.handlers).stopSync(nil)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
