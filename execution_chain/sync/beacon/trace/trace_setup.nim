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
  pkg/chronicles,
  ./trace_desc

logScope:
  topics = "beacon trace"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

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

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc traceSetup*(
    ctx: BeaconCtxRef;
    fileName: string;
    nSessions: int;
      ): bool =
  ## ..
  const info = "traceSetup(): "

  if ctx.handler.version != 0:
    error info & "Overlay session handlers activated already",
      ID=ctx.handler.version
    return false

  if fileName.fileExists: # File must not exist yet
    error info & "Unsafe, please delete file first", fileName
    return false

  var strm = Stream(nil)
  info.onException(DontQuit):
    # Note that there is a race condition. The proper open mode shoud be
    # `fmReadWriteExisting` (sort of resembling `O_CREATE|O_EXCL`) but it
    # does not work with the current nim version `2.2.4`.
    var fd: File
    if fd.open(fileName, fmWrite):
      strm = fd.newFileStream()

  if strm.isNil:
    error info & "Cannot open trace file for writing", fileName
    return false

  ctx.pool.handlers = TraceBaseHandlersRef(
    version:         TraceBaseHandlersID,
    strm:            strm,
    nSessions:       nSessions,
    activate:        ctx.handler.activate,
    suspend:         ctx.handler.suspend,
    schedDaemon:     ctx.handler.schedDaemon,
    schedStart:      ctx.handler.schedStart,
    schedStop:       ctx.handler.schedStop,
    schedPool:       ctx.handler.schedPool,
    schedPeer:       ctx.handler.schedPeer,
    beginHeaders:    ctx.handler.beginHeaders,
    getBlockHeaders: ctx.handler.getBlockHeaders,
    beginBlocks:     ctx.handler.beginBlocks,
    getBlockBodies:  ctx.handler.getBlockBodies,
    importBlock:     ctx.handler.importBlock)

  true

proc traceRelease*(ctx: BeaconCtxRef) =
  const info = "traceRelease(): "

  if ctx.handler.version == TraceBaseHandlersID:
    info.onException(DontQuit):
      ctx.handler.TraceBaseHandlersRef.strm.close()
    ctx.pool.handlers.version = 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
