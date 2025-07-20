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
  std/streams,
  pkg/[chronicles, chronos],
  ./replay_reader/reader_init,
  ./replay_runner/runner_init,
  ./replay_start_stop/handlers/[blocks, headers, sched, sync],
  ./[replay_desc, replay_runner]

logScope:
  topics = "replay"

const
  startInfo = "replayStart(): "

# ------------------------------------------------------------------------------
# Private helper(s)
# ------------------------------------------------------------------------------

proc destroy(rpl: ReplayRef; info: static[string]) =
  info info & "Terminating .."
  rpl.reader.destroy()
  rpl.runner.destroy()

proc unlessStop(rpl: ReplayRef; info: static[string]): ReplayStopRunnnerFn =
  let ctx = rpl.runner.ctx
  proc(): bool =
    if ctx.handler.version != 20 or
       rpl.runner.stopRunner:
      rpl.destroy info
      return true
    false

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc phoneySched(ctx: BeaconCtxRef) {.async: (raises: []).} =
  const info = "phoneySched(): "
  let rpl = ctx.replay
  if rpl.isNil:
    warn info & "No usable syncer environment",
      handlerVersion=ctx.handler.version
  else:
    await rpl.runner.runDispatcher(rpl.reader, stopIf=rpl.unlessStop info)

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc replayStop*(ctx: BeaconCtxRef) =
  let rpl = ctx.replay
  if not rpl.isNil:
    # Signals shutdown to `phonySched()`
    ctx.pool.handlers = rpl.backup


proc replayStart*(ctx: BeaconCtxRef; strm: Stream) =
  ## Start replay emulator
  ##
  if ctx.handler.version in {0, ReplayBaseHandlersID}:
    ctx.pool.handlers = ReplayRef(

      # Install new Overlay handler descriptor
      reader:          ReplayReaderRef.init(strm),
      backup:          ctx.pool.handlers,
      runner:          ReplayRunnerRef.init(ctx),

      # Set up redirect handlers for tracing
      version:         ReplayOverlayHandlersID,
      activate:        activateReplay,
      suspend:         suspendReplay,
      schedDaemon:     schedDaemonMuted,
      schedStart:      schedStartMuted,
      schedStop:       schedStopMuted,
      schedPool:       schedPoolMuted,
      schedPeer:       schedPeerMuted,
      getBlockHeaders: fetchHeadersReplay,
      getBlockBodies:  fetchBodiesReplay,
      importBlock:     importBlockReplay)

    # Start fake scheduler
    asyncSpawn ctx.phoneySched()

  elif ctx.handler.version != ReplayOverlayHandlersID:
    fatal startInfo & "Overlay session handlers activated already",
      ID=ctx.handler.version
    quit(QuitFailure)


proc replayStart*(ctx: BeaconCtxRef) =
  ## Variant of `traceStart()` for pre-initialised handlers (see
  ## `replaySetup()`.)
  ##
  if ctx.handler.version == ReplayBaseHandlersID:
    let hdl = ctx.handler.ReplayBaseHandlersRef
    ctx.replayStart(hdl.strm)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
