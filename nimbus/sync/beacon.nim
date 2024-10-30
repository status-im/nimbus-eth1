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
  ../core/chain,
  ./beacon/[worker, worker_desc, worker/db],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "beacon sync"

type
  BeaconSyncRef* = RunnerSyncRef[BeaconCtxData,BeaconBuddyData]

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  worker.setup(ctx, "RunSetup")

proc runRelease(ctx: BeaconCtxRef) =
  worker.release(ctx, "RunRelease")

proc runDaemon(ctx: BeaconCtxRef) {.async, raises: [].} =
  await worker.runDaemon(ctx, "RunDaemon")

proc runStart(buddy: BeaconBuddyRef): bool =
  worker.start(buddy, "RunStart")

proc runStop(buddy: BeaconBuddyRef) =
  worker.stop(buddy, "RunStop")

proc runPool(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps, "RunPool")

proc runPeer(buddy: BeaconBuddyRef) {.async, raises: [].} =
  await worker.runPeer(buddy, "RunPeer")

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type BeaconSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
    chunkSize = 0;
      ): T =
  var desc = T()
  desc.initSync(ethNode, maxPeers)
  desc.ctx.pool.nBodiesBatch = chunkSize
  desc.ctx.pool.chain = chain
  desc

proc start*(desc: BeaconSyncRef): bool =
  desc.startSync()

proc stop*(desc: BeaconSyncRef) =
  desc.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
