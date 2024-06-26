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
  eth/p2p,
  chronicles,
  chronos,
  stew/[interval_set, sorted_set],
  ./beacon/[worker, worker_desc, beacon_impl],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "beacon-sync"

type
  BeaconSyncRef* = RunnerSyncRef[BeaconCtxData,BeaconBuddyData]

const
  extraTraceMessages = false # or true
    ## Enable additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template traceMsg(f, info: static[string]; args: varargs[untyped]) =
  trace "Snap scheduler " & f & "() " & info, args

template traceMsgCtx(f, info: static[string]; c: BeaconCtxRef) =
  when extraTraceMessages:
    block:
      let
        poolMode {.inject.} = c.poolMode
        daemon   {.inject.} = c.daemon
      f.traceMsg info, poolMode, daemon

template traceMsgBuddy(f, info: static[string]; b: BeaconBuddyRef) =
  when extraTraceMessages:
    block:
      let
        peer     {.inject.} = b.peer
        runState {.inject.} = b.ctrl.state
        multiOk  {.inject.} = b.ctrl.multiOk
        poolMode {.inject.} = b.ctx.poolMode
        daemon   {.inject.} = b.ctx.daemon
      f.traceMsg info, peer, runState, multiOk, poolMode, daemon


template tracerFrameCtx(f: static[string]; c: BeaconCtxRef; code: untyped) =
  f.traceMsgCtx "begin", c
  code
  f.traceMsgCtx "end", c

template tracerFrameBuddy(f: static[string]; b: BeaconBuddyRef; code: untyped) =
  f.traceMsgBuddy "begin", b
  code
  f.traceMsgBuddy "end", b

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  tracerFrameCtx("runSetup", ctx):
    result = worker.setup(ctx)

proc runRelease(ctx: BeaconCtxRef) =
  tracerFrameCtx("runRelease", ctx):
    worker.release(ctx)

proc runDaemon(ctx: BeaconCtxRef) {.async.} =
  tracerFrameCtx("runDaemon", ctx):
    await worker.runDaemon(ctx)

proc runStart(buddy: BeaconBuddyRef): bool =
  tracerFrameBuddy("runStart", buddy):
    result = worker.start(buddy)

proc runStop(buddy: BeaconBuddyRef) =
  tracerFrameBuddy("runStop", buddy):
    worker.stop(buddy)

proc runPool(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  tracerFrameBuddy("runPool", buddy):
    result = worker.runPool(buddy, last, laps)

proc runSingle(buddy: BeaconBuddyRef) {.async.} =
  tracerFrameBuddy("runSingle", buddy):
    await worker.runSingle(buddy)

proc runMulti(buddy: BeaconBuddyRef) {.async.} =
  tracerFrameBuddy("runMulti", buddy):
    await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func updateBeaconHeaderCB(ctx: BeaconSyncRef): SyncReqNewHeadCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  result = proc(h: BlockHeader) {.gcsafe, raises: [].} =
    try:
      debug "REQUEST SYNC", number=h.number, hash=h.blockHash.short
      waitFor ctx.ctx.appendSyncTarget(h)
    except CatchableError as ex:
      error "updateBeconHeaderCB error", msg=ex.msg

proc enableRpcMagic(ctx: BeaconSyncRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  let com = ctx.ctx.chain.com
  com.syncReqNewHead = ctx.updateBeaconHeaderCB

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type BeaconSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    rng: ref HmacDrbgContext;
    maxPeers: int;
    id: int = 0): T =
  new result
  result.initSync(ethNode, chain, maxPeers, Opt.none(string))
  result.ctx.pool.rng = rng
  result.ctx.pool.id = id

proc start*(ctx: BeaconSyncRef) =
  ## Beacon Sync always begin with stop mode
  doAssert ctx.startSync()      # Initialize subsystems
  ctx.enableRpcMagic()      # Allow external pivot update via RPC

proc stop*(ctx: BeaconSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
