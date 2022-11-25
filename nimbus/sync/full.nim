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
  stew/[interval_set, sorted_set],
  "."/[full/worker, sync_desc, sync_sched, protocol]

{.push raises: [Defect].}

logScope:
  topics = "full-sync"

type
  FullSyncRef* = RunnerSyncRef[CtxData,BuddyData]

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: FullCtxRef; ticker: bool): bool =
  worker.setup(ctx,ticker)

proc runRelease(ctx: FullCtxRef) =
  worker.release(ctx)

proc runDaemon(ctx: FullCtxRef) {.async.} =
  discard

proc runStart(buddy: FullBuddyRef): bool =
  worker.start(buddy)

proc runStop(buddy: FullBuddyRef) =
  worker.stop(buddy)

proc runPool(buddy: FullBuddyRef; last: bool): bool =
  worker.runPool(buddy, last)

proc runSingle(buddy: FullBuddyRef) {.async.} =
  await worker.runSingle(buddy)

proc runMulti(buddy: FullBuddyRef) {.async.} =
  await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type FullSyncRef;
    ethNode: EthereumNode;
    chain: Chain;
    rng: ref HmacDrbgContext;
    maxPeers: int;
    enableTicker = false): T =
  new result
  result.initSync(ethNode, chain, maxPeers, enableTicker)
  result.ctx.data.rng = rng

proc start*(ctx: FullSyncRef) =
  doAssert ctx.startSync()

proc stop*(ctx: FullSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
