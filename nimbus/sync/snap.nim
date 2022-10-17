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
  eth/[common/eth_types, p2p],
  chronicles,
  chronos,
  ../db/select_backend,
  ../p2p/chain,
  ./snap/[worker, worker_desc],
  "."/[protocol, sync_desc, sync_sched]

{.push raises: [Defect].}

logScope:
  topics = "snap-sync"

type
  SnapSyncRef* = RunnerSyncRef[CtxData,BuddyData]

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: SnapCtxRef; ticker: bool): bool =
  worker.setup(ctx,ticker)

proc runRelease(ctx: SnapCtxRef) =
  worker.release(ctx)

proc runStart(buddy: SnapBuddyRef): bool =
  worker.start(buddy)

proc runStop(buddy: SnapBuddyRef) =
  worker.stop(buddy)

proc runPool(buddy: SnapBuddyRef; last: bool) =
  worker.runPool(buddy, last)

proc runSingle(buddy: SnapBuddyRef) {.async.} =
  await worker.runSingle(buddy)

proc runMulti(buddy: SnapBuddyRef) {.async.} =
  await worker.runMulti(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapSyncRef;
    ethNode: EthereumNode;
    chain: Chain;
    rng: ref HmacDrbgContext;
    maxPeers: int;
    dbBackend: ChainDb,
    enableTicker = false): T =
  new result
  result.initSync(ethNode, chain, maxPeers, enableTicker)
  result.ctx.chain = chain # explicitely override
  result.ctx.data.rng = rng
  result.ctx.data.dbBackend = dbBackend
  # Required to have been initialised via `addCapability()`
  doAssert not result.ctx.ethWireCtx.isNil

proc start*(ctx: SnapSyncRef) =
  doAssert ctx.startSync()

proc stop*(ctx: SnapSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
