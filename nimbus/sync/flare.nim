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
  ./flare/[worker, worker_desc],
  "."/[sync_desc, sync_sched, protocol]

logScope:
  topics = "flare"

type
  FlareSyncRef* = RunnerSyncRef[FlareCtxData,FlareBuddyData]

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: FlareCtxRef): bool =
  worker.setup(ctx)

proc runRelease(ctx: FlareCtxRef) =
  worker.release(ctx)

proc runDaemon(ctx: FlareCtxRef) {.async.} =
  await worker.runDaemon(ctx)

proc runStart(buddy: FlareBuddyRef): bool =
  worker.start(buddy)

proc runStop(buddy: FlareBuddyRef) =
  worker.stop(buddy)

proc runPool(buddy: FlareBuddyRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps)

proc runPeer(buddy: FlareBuddyRef) {.async.} =
  await worker.runPeer(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type FlareSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
    chunkSize: int;
      ): T =
  var desc = T()
  desc.initSync(ethNode, chain, maxPeers)
  desc.ctx.pool.nBodiesBatch = chunkSize
  # Initalise for `persistBlocks()`
  desc.ctx.pool.chain = chain.com.newChain()
  desc

proc start*(ctx: FlareSyncRef) =
  ## Beacon Sync always begin with stop mode
  doAssert ctx.startSync()      # Initialize subsystems

proc stop*(ctx: FlareSyncRef) =
  ctx.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
