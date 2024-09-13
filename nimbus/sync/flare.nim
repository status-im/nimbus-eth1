# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos, eth/p2p, results],
  pkg/stew/[interval_set, sorted_set],
  ./flare/[worker, worker_desc],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "flare"

type
  FlareSyncRef* = RunnerSyncRef[FlareCtxData,FlareBuddyData]

const
  extraTraceMessages = false # or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template traceMsg(f, info: static[string]; args: varargs[untyped]) =
  trace "Flare scheduler " & f & "() " & info, args

template traceMsgCtx(f, info: static[string]; c: FlareCtxRef) =
  when extraTraceMessages:
    block:
      let
        poolMode {.inject.} = c.poolMode
        daemon   {.inject.} = c.daemon
      f.traceMsg info, poolMode, daemon

template traceMsgBuddy(f, info: static[string]; b: FlareBuddyRef) =
  when extraTraceMessages:
    block:
      let
        peer     {.inject.} = b.peer
        runState {.inject.} = b.ctrl.state
        multiOk  {.inject.} = b.ctrl.multiOk
        poolMode {.inject.} = b.ctx.poolMode
        daemon   {.inject.} = b.ctx.daemon
      f.traceMsg info, peer, runState, multiOk, poolMode, daemon


template tracerFrameCtx(f: static[string]; c: FlareCtxRef; code: untyped) =
  f.traceMsgCtx "begin", c
  code
  f.traceMsgCtx "end", c

template tracerFrameBuddy(f: static[string]; b: FlareBuddyRef; code: untyped) =
  f.traceMsgBuddy "begin", b
  code
  f.traceMsgBuddy "end", b

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: FlareCtxRef): bool =
  tracerFrameCtx("runSetup", ctx):
    result = worker.setup(ctx)

proc runRelease(ctx: FlareCtxRef) =
  tracerFrameCtx("runRelease", ctx):
    worker.release(ctx)

proc runDaemon(ctx: FlareCtxRef) {.async.} =
  tracerFrameCtx("runDaemon", ctx):
    await worker.runDaemon(ctx)

proc runStart(buddy: FlareBuddyRef): bool =
  tracerFrameBuddy("runStart", buddy):
    result = worker.start(buddy)

proc runStop(buddy: FlareBuddyRef) =
  tracerFrameBuddy("runStop", buddy):
    worker.stop(buddy)

proc runPool(buddy: FlareBuddyRef; last: bool; laps: int): bool =
  tracerFrameBuddy("runPool", buddy):
    result = worker.runPool(buddy, last, laps)

proc runSingle(buddy: FlareBuddyRef) {.async.} =
  tracerFrameBuddy("runSingle", buddy):
    await worker.runSingle(buddy)

proc runMulti(buddy: FlareBuddyRef) {.async.} =
  tracerFrameBuddy("runMulti", buddy):
    await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type FlareSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
      ): T =
  new result
  result.initSync(ethNode, chain, maxPeers)

proc start*(ctx: FlareSyncRef) =
  ## Beacon Sync always begin with stop mode
  doAssert ctx.startSync()      # Initialize subsystems

proc stop*(ctx: FlareSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
