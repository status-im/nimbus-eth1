# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/[common, p2p],
  chronicles,
  chronos,
  stew/[interval_set, sorted_set],
  ./full/[worker, worker_desc],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "full-sync"

type
  FullSyncRef* = RunnerSyncRef[CtxData,BuddyData]

const
  extraTraceMessages = false # or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template traceMsg(f, info: static[string]; args: varargs[untyped]) =
  trace "Snap scheduler " & f & "() " & info, args

template traceMsgCtx(f, info: static[string]; c: FullCtxRef) =
  when extraTraceMessages:
    block:
      let
        poolMode {.inject.} = c.poolMode
        daemon   {.inject.} = c.daemon
      f.traceMsg info, poolMode, daemon

template traceMsgBuddy(f, info: static[string]; b: FullBuddyRef) =
  when extraTraceMessages:
    block:
      let
        peer     {.inject.} = b.peer
        runState {.inject.} = b.ctrl.state
        multiOk  {.inject.} = b.ctrl.multiOk
        poolMode {.inject.} = b.ctx.poolMode
        daemon   {.inject.} = b.ctx.daemon
      f.traceMsg info, peer, runState, multiOk, poolMode, daemon


template tracerFrameCtx(f: static[string]; c: FullCtxRef; code: untyped) =
  f.traceMsgCtx "begin", c
  code
  f.traceMsgCtx "end", c

template tracerFrameBuddy(f: static[string]; b: FullBuddyRef; code: untyped) =
  f.traceMsgBuddy "begin", b
  code
  f.traceMsgBuddy "end", b

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: FullCtxRef; ticker: bool): bool =
  tracerFrameCtx("runSetup", ctx):
    result = worker.setup(ctx,ticker)

proc runRelease(ctx: FullCtxRef) =
  tracerFrameCtx("runRelease", ctx):
    worker.release(ctx)

proc runDaemon(ctx: FullCtxRef) {.async.} =
  tracerFrameCtx("runDaemon", ctx):
    await worker.runDaemon(ctx)

proc runStart(buddy: FullBuddyRef): bool =
  tracerFrameBuddy("runStart", buddy):
    result = worker.start(buddy)

proc runStop(buddy: FullBuddyRef) =
  tracerFrameBuddy("runStop", buddy):
    worker.stop(buddy)

proc runPool(buddy: FullBuddyRef; last: bool): bool =
  tracerFrameBuddy("runPool", buddy):
    result = worker.runPool(buddy, last)

proc runSingle(buddy: FullBuddyRef) {.async.} =
  tracerFrameBuddy("runSingle", buddy):
    await worker.runSingle(buddy)

proc runMulti(buddy: FullBuddyRef) {.async.} =
  tracerFrameBuddy("runMulti", buddy):
    await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type FullSyncRef;
    ethNode: EthereumNode;
    chain: ChainRef;
    rng: ref HmacDrbgContext;
    maxPeers: int;
    enableTicker = false): T =
  new result
  result.initSync(ethNode, chain, maxPeers, enableTicker)
  result.ctx.pool.rng = rng

proc start*(ctx: FullSyncRef) =
  doAssert ctx.startSync()

proc stop*(ctx: FullSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
