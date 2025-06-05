# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos, results],
  pkg/stew/[interval_set, sorted_set],
  ../core/chain,
  ../networking/p2p,
  ./beacon/worker/blocks/blocks_fetch as bodies,
  ./beacon/worker/blocks/blocks_import as blocks,
  ./beacon/worker/headers/headers_fetch as headers,
  ./beacon/worker/update,
  ./beacon/[trace, worker, worker_desc],
  ./[sync_desc, sync_sched, wire_protocol]

logScope:
  topics = "beacon sync"

type
  BeaconSyncRef* = RunnerSyncRef[BeaconCtxData,BeaconBuddyData]

# ------------------------------------------------------------------------------
# Interceptable handlers
# ------------------------------------------------------------------------------

proc schedDaemonCB(ctx: BeaconCtxRef) {.async: (raises: []).} =
  await worker.runDaemon(ctx, "RunDaemon")

proc schedStartCB(buddy: BeaconBuddyRef): bool =
  worker.start(buddy, "RunStart")

proc schedStopCB(buddy: BeaconBuddyRef) =
  worker.stop(buddy, "RunStop")

proc schedPoolCB(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps, "RunPool")

proc schedPeerCB(buddy: BeaconBuddyRef) {.async: (raises: []).} =
  await worker.runPeer(buddy, "RunPeer")

proc muteBeginCB(buddy: BeaconBuddyRef) {.async: (raises: []).} =
  discard

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  worker.setup(ctx, "RunSetup")

proc runRelease(ctx: BeaconCtxRef) =
  worker.release(ctx, "RunRelease")

proc runTicker(ctx: BeaconCtxRef) =
  worker.runTicker(ctx, "RunTicker")


proc runDaemon(ctx: BeaconCtxRef) {.async: (raises: []).} =
  await ctx.handler.schedDaemon(ctx)

proc runStart(buddy: BeaconBuddyRef): bool =
  buddy.ctx.handler.schedStart(buddy)

proc runStop(buddy: BeaconBuddyRef) =
  buddy.ctx.handler.schedStop(buddy)

proc runPool(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  buddy.ctx.handler.schedPool(buddy, last, laps)

proc runPeer(buddy: BeaconBuddyRef) {.async: (raises: []).} =
  await buddy.ctx.handler.schedPeer(buddy)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type BeaconSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
      ): T =
  var desc = T()
  desc.initSync(ethNode, maxPeers)
  desc.ctx.pool.chain = chain

  # Set up handlers so they can be overlayed
  desc.ctx.pool.handlers = BeaconHandlersRef(
    version:         0,
    activate:        updateActivateCB,
    suspend:         updateSuspendCB,
    schedDaemon:     schedDaemonCB,
    schedStart:      schedStartCB,
    schedStop:       schedStopCB,
    schedPool:       schedPoolCB,
    schedPeer:       schedPeerCB,
    beginHeaders:    muteBeginCB,
    getBlockHeaders: getBlockHeadersCB,
    beginBlocks:     muteBeginCB,
    getBlockBodies:  getBlockBodiesCB,
    importBlock:     blocks.importCB)

  desc

proc tracerInit*(desc: BeaconSyncRef; outFile: string, nSessions: int) =
  ## Set up tracer (not be called when replay is enabled)
  if not desc.ctx.traceSetup(outFile, nSessions):
    fatal "Cannot set up trace handlers -- STOP", fileName=outFile, nSessions
    quit(QuitFailure)

proc targetInit*(desc: BeaconSyncRef; rlpFile: string) =
  ## Set up inital sprint (intended for debugging)
  doAssert desc.ctx.handler.version == 0
  desc.ctx.initalTargetFromFile(rlpFile, "targetInit").isOkOr:
    raiseAssert error

proc start*(desc: BeaconSyncRef): bool =
  if desc.startSync():
    desc.ctx.traceStart()
    return true
  # false

proc stop*(desc: BeaconSyncRef) {.async.} =
  desc.ctx.traceStop()
  desc.ctx.traceRelease()
  await desc.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
