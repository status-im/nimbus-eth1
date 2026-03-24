# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[dirs, paths],
  pkg/[chronicles, chronos, results],
  pkg/stew/[interval_set, sorted_set],
  ../core/chain,
  ../networking/p2p,
  ./snap/[snap_desc, worker],
  ./snap/worker/[helpers, update],
  ./[sync_sched, wire_protocol]

from ./beacon
  import BeaconSyncRef, start

export
  snap_desc

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: SnapCtxRef): bool =
  worker.setup(ctx, "Setup")

proc runRelease(ctx: SnapCtxRef) =
  worker.release(ctx, "Release")

proc runDaemon(ctx: SnapCtxRef): Future[Duration] {.async: (raises: []).} =
  return worker.runDaemon(ctx, "Daemon")

proc runTicker(ctx: SnapCtxRef) =
  worker.runTicker(ctx, "Ticker")

proc runStart(buddy: SnapPeerRef): bool =
  worker.start(buddy, "Start")

proc runStop(buddy: SnapPeerRef) =
  worker.stop(buddy, "Stop")

proc runPool(buddy: SnapPeerRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps, "SyncMode")

proc runPeer(buddy: SnapPeerRef): Future[Duration] {.async: (raises: []).} =
  return worker.runPeer(buddy, "Peer")

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapSyncRef;
    configCB = SnapSyncConfigHook(nil);
      ): T =
  ## Constructor
  ##
  ## The `configCB` allows to specify a final configuration task to be run at
  ## the end of the `config()` function.
  ##
  T(lazyConfigHook: configCB)

proc config*(
    desc: SnapSyncRef;
    ethNode: EthereumNode;
    maxPeers: int;
      ) =
  ## Complete `SnapSyncRef` descriptor initialisation.
  ##
  ## Note that the `init()` constructor might have specified a configuration
  ## task to be run at the end of the `config()` function.
  ##
  doAssert desc.ctx.isNil # This can only run once
  desc.initSync(ethNode, maxPeers)
  desc.addSyncProtocol snap1

  if not desc.lazyConfigHook.isNil:
    desc.lazyConfigHook(desc)
    desc.lazyConfigHook = nil

proc configBaseDir*(desc: SnapSyncRef; dir: string) =
  ## Set up database folder.
  doAssert not desc.ctx.isNil
  desc.ctx.pool.baseDir = dir

proc configResume*(desc: SnapSyncRef; resume = true) =
  ## Set syncer into resume (or no-resume) mode. By default, the syncer is
  ## in no-resume mode.
  doAssert not desc.ctx.isNil
  if resume: desc.ctx.updateSyncResume()
  else: desc.ctx.updateSyncReset()

proc configTarget*(desc: SnapSyncRef; hex: string): bool =
  ## Set up inital target root (if any, mainly for debugging)
  doAssert not desc.ctx.isNil
  try:
    desc.ctx.pool.target = Opt.some(BlockHash Hash32.fromHex(hex))
    return true
  except ValueError:
    discard
  # false

proc start*(desc: SnapSyncRef; bcSyncRef: BeaconSyncRef): bool =
  ## Starting beacon sync in stand-by mode and then snap sync.
  doAssert not desc.ctx.isNil
  doAssert not bcSyncRef.isNil
  desc.ctx.pool.beaconSync = bcSyncRef
  if not desc.isRunning and
     desc.ctx.pool.beaconSync.start(standBy=true) and
     desc.startSync():
    return true
  # false

proc stop*(desc: SnapSyncRef) {.async.} =
  doAssert not desc.ctx.isNil
  await desc.stopSync()
  desc.ctx.pool.reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
