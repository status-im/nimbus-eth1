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
  std/[streams, strutils],
  pkg/[chronicles, chronos],
  ../../../execution_chain/sync/wire_protocol,
  ./replay_reader/reader_init,
  ./replay_runner/runner_dispatch/[dispatch_blocks, dispatch_headers],
  ./replay_runner/[runner_desc, runner_init],
  ./replay_runner

logScope:
  topics = "beacon replay"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

  stopInfo = "replayStop()"

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
# Private replacement handlers
# ------------------------------------------------------------------------------

proc noOpBuddy(buddy: BeaconBuddyRef) =
  discard

proc noOpSchedStartFalse(buddy: BeaconBuddyRef): bool =
  return false

proc noOpSchedPoolTrue(a: BeaconBuddyRef, b: bool, c: int): bool =
  return true

proc noOpSchedDaemon(ctx: BeaconCtxRef):
    Future[Duration] {.async: (raises: []).} =
  return replayWaitMuted

proc noOpSchedPeer(buddy: BeaconBuddyRef):
    Future[Duration] {.async: (raises: []).} =
  return replayWaitMuted

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc checkStop(rpl: ReplayRunnerRef): ReplayStopIfFn =
  proc(): bool =
    if rpl.stopRunner:
      return true
    false

proc cleanUp(rpl: ReplayRunnerRef): ReplayEndUpFn =
   proc() =
     rpl.stopSync(rpl)
     if rpl.stopQuit:
       notice stopInfo & ": quitting .."
       quit(QuitSuccess)
     else:
       info stopInfo & ": terminating .."

# --------------

proc replayStartCB(rpl: ReplayRunnerRef) =
  ## Start replay emulator
  ##
  # Set up redirect handlers for replay
  rpl.version =          ReplayRunnerID
  #   activate                               # use as is
  #   suspend                                # use as is
  rpl.reader =           ReplayReaderRef.init(rpl.captStrm)
  rpl.schedDaemon =      noOpSchedDaemon
  rpl.schedStart =       noOpSchedStartFalse # `false` => don't register
  rpl.schedStop =        noOpBuddy
  rpl.schedPool =        noOpSchedPoolTrue   # `true` => stop repeating
  rpl.schedPeer =        noOpSchedPeer
  rpl.getBlockHeaders =  fetchHeadersHandler # from dispatcher
  rpl.syncBlockHeaders = noOpBuddy
  rpl.getBlockBodies =   fetchBodiesHandler  # from dispatcher
  rpl.syncBlockBodies =  noOpBuddy
  rpl.importBlock =      importBlockHandler  # from dispatcher
  rpl.syncImportBlock =  noOpBuddy

  rpl.initRunner()

  rpl.startSync = proc(self: BeaconHandlersSyncRef) =
    discard

  rpl.stopSync = proc(self: BeaconHandlersSyncRef) =
    ReplayRunnerRef(self).reader.destroy()
    ReplayRunnerRef(self).destroyRunner()
    stopInfo.onException(DontQuit):
      ReplayRunnerRef(self).captStrm.close()
    ReplayRunnerRef(self).ctx.pool.handlers = ReplayRunnerRef(self).backup

  # Start fake scheduler
  asyncSpawn rpl.runDispatcher(
    rpl.reader, stopIf=rpl.checkStop, endUp=rpl.cleanUp)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc replaySetup*(
    ctx: BeaconCtxRef;
    fileName: string;
    noStopQuit: bool;
    fakeImport: bool;
      ): Result[void,string] =
  ## setup replay emulator
  ##
  const info = "replaySetup(): "

  if ctx.handler.version != 0:
    return err("Overlay session handlers activated already" &
               "ID=" & $ctx.handler.version)

  let strm = fileName.newFileStream fmRead
  if strm.isNil:
    return err("Cannot open trace file for reading" &
               ", fileName=\"" & fileName & "\"")

  let rpl = ReplayRunnerRef(
    ctx:              ctx,
    captStrm:         strm,
    fakeImport:       fakeImport,
    stopQuit:         not noStopQuit,
    backup:           ctx.pool.handlers,

    # This is still the old descriptor which will be updated when
    # `startSync()` is run.
    version:          ReplayRunnerID,
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

  rpl.startSync = proc(self: BeaconHandlersSyncRef) =
    ReplayRunnerRef(self).replayStartCB()

  rpl.stopSync = proc(self: BeaconHandlersSyncRef) =
    info.onException(DontQuit):
      ReplayRunnerRef(self).captStrm.close()
    ReplayRunnerRef(self).ctx.pool.handlers = ReplayRunnerRef(self).backup

  ctx.pool.handlers = rpl
  ok()


proc replayRelease*(ctx: BeaconCtxRef) =
  ## Stop replay and restore descriptors
  if ctx.pool.handlers.version in {ReplaySetupID, ReplayRunnerID}:
    ReplayRunnerRef(ctx.pool.handlers).stopSync(nil)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
