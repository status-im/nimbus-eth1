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
  pkg/chronicles,
  ./replay_desc

logScope:
  topics = "beacon reaplay"

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
    const blurb = info & "Replay stream exception -- STOP"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb, error=($e.name), msg=e.msg
      quit(quitCode)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc replaySetup*(
    ctx: BeaconCtxRef;
    fileName: string;
      ): bool =
  ## ..
  const info = "replaySetup(): "

  if ctx.handler.version != 0:
    error info & "Overlay session handlers activated already",
      ID=ctx.handler.version
    return false

  let strm = fileName.newFileStream fmRead
  if strm.isNil:
    error info & "Cannot open trace file for reading", fileName
    return false

  ctx.pool.handlers = ReplayBaseHandlersRef(
    version:         ReplayBaseHandlersID,
    strm:            strm,
    activate:        ctx.handler.activate,
    suspend:         ctx.handler.suspend,
    schedDaemon:     ctx.handler.schedDaemon,
    schedStart:      ctx.handler.schedStart,
    schedStop:       ctx.handler.schedStop,
    schedPool:       ctx.handler.schedPool,
    schedPeer:       ctx.handler.schedPeer,
    getBlockHeaders: ctx.handler.getBlockHeaders,
    getBlockBodies:  ctx.handler.getBlockBodies,
    importBlock:     ctx.handler.importBlock)

  true

proc replayRelease*(ctx: BeaconCtxRef) =
  const info = "replayRelease(): "

  if ctx.handler.version == ReplayBaseHandlersID:
    info.onException(DontQuit):
      ctx.handler.ReplayBaseHandlersRef.strm.close()
    ctx.pool.handlers.version = 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
