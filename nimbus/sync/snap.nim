# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/[common, p2p],
  chronicles,
  chronos,
  ../db/select_backend,
  ../core/chain,
  ./snap/[worker, worker_desc],
  "."/[protocol, sync_desc, sync_sched]

{.push raises: [Defect].}

logScope:
  topics = "snap-sync"

type
  SnapSyncRef* = RunnerSyncRef[CtxData,BuddyData]

const
  extraTraceMessages = false # or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template traceMsg(f, info: static[string]; args: varargs[untyped]) =
  trace "Snap scheduler " & f & "() " & info, args

template traceMsgCtx(f, info: static[string]; c: SnapCtxRef) =
  when extraTraceMessages:
    block:
      let
        poolMode {.inject.} = c.poolMode
        daemon   {.inject.} = c.daemon
      f.traceMsg info, poolMode, daemon

template traceMsgBuddy(f, info: static[string]; b: SnapBuddyRef) =
  when extraTraceMessages:
    block:
      let
        peer     {.inject.} = b.peer
        runState {.inject.} = b.ctrl.state
        multiOk  {.inject.} = b.ctrl.multiOk
        poolMode {.inject.} = b.ctx.poolMode
        daemon   {.inject.} = b.ctx.daemon
      f.traceMsg info, peer, runState, multiOk, poolMode, daemon


template tracerFrameCtx(f: static[string]; c: SnapCtxRef; code: untyped) =
  f.traceMsgCtx "begin", c
  code
  f.traceMsgCtx "end", c

template tracerFrameBuddy(f: static[string]; b: SnapBuddyRef; code: untyped) =
  f.traceMsgBuddy "begin", b
  code
  f.traceMsgBuddy "end", b

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: SnapCtxRef; ticker: bool): bool =
  tracerFrameCtx("runSetup", ctx):
    result = worker.setup(ctx,ticker)

proc runRelease(ctx: SnapCtxRef) =
  tracerFrameCtx("runRelease", ctx):
    worker.release(ctx)

proc runDaemon(ctx: SnapCtxRef) {.async.} =
  tracerFrameCtx("runDaemon", ctx):
    await worker.runDaemon(ctx)

proc runStart(buddy: SnapBuddyRef): bool =
  tracerFrameBuddy("runStart", buddy):
    result = worker.start(buddy)

proc runStop(buddy: SnapBuddyRef) =
  tracerFrameBuddy("runStop", buddy):
    worker.stop(buddy)

proc runPool(buddy: SnapBuddyRef; last: bool): bool =
  tracerFrameBuddy("runPool", buddy):
    result = worker.runPool(buddy, last)

proc runSingle(buddy: SnapBuddyRef) {.async.} =
  tracerFrameBuddy("runSingle", buddy):
    await worker.runSingle(buddy)

proc runMulti(buddy: SnapBuddyRef) {.async.} =
  tracerFrameBuddy("runMulti", buddy):
    await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapSyncRef;
    ethNode: EthereumNode;
    chain: ChainRef;
    rng: ref HmacDrbgContext;
    maxPeers: int;
    dbBackend: ChainDb;
    enableTicker = false;
    noRecovery = false;
      ): T =
  new result
  result.initSync(ethNode, chain, maxPeers, enableTicker)
  result.ctx.chain = chain # explicitely override
  result.ctx.data.rng = rng
  result.ctx.data.dbBackend = dbBackend
  result.ctx.data.noRecovery = noRecovery
  # Required to have been initialised via `addEthHandlerCapability()`
  doAssert not result.ctx.ethWireCtx.isNil

proc start*(ctx: SnapSyncRef) =
  doAssert ctx.startSync()

proc stop*(ctx: SnapSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
