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
  std/paths,
  pkg/[chronicles, chronos, results],
  pkg/stew/[interval_set, sorted_set],
  ../core/chain,
  ../networking/p2p,
  ./snap/[snap_desc, worker],
  ./snap/worker/helpers,
  ./[sync_sched, wire_protocol]

from ./beacon
  import BeaconSyncRef, start

export
  snap_desc

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc addSnapSyncProtocol(desc: SnapSyncRef; PROTO: type) =
  ## Add protocol and call back filter & init functions for ethXX
  proc initWorker(worker: SyncPeerRef[SnapCtxData,SnapPeerData]) =
    when PROTO is snap1:
      discard
    elif PROTO is snap2:
      worker.only.supportsBal = true
    else:
      {.error: "Unsupported snap/?? version".}

  desc.addSyncProtocol(PROTO, initWorker=initWorker)

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
    dataDir: string;
    maxPeers: int;
      ) =
  ## Complete `SnapSyncRef` descriptor initialisation.
  ##
  ## Note that the `init()` constructor might have specified a configuration
  ## task to be run at the end of the `config()` function.
  ##
  doAssert desc.ctx.isNil                           # This can only run once
  desc.initSync(ethNode, maxPeers)

  # The registration order for protocols is largely irrelevant, yet the first
  # will always be compared with the activated protocol which is likely to be
  # expected the latest version of the `snap` protocol family.
  desc.addSnapSyncProtocol(snap2)
  desc.addSnapSyncProtocol(snap1)

  desc.ctx.pool.baseDir = dataDir

  if not desc.lazyConfigHook.isNil:
    desc.lazyConfigHook(desc)
    desc.lazyConfigHook = nil

proc configResume*(desc: SnapSyncRef; resume = true) =
  ## Set syncer into resume (or no-resume) mode. By default, the syncer is
  ## in no-resume mode.
  doAssert not desc.ctx.isNil
  desc.ctx.pool.contPrevSession = true

proc start*(desc: SnapSyncRef; bcSyncRef: BeaconSyncRef): bool =
  ## Starting beacon sync in stand-by mode and then snap sync.
  doAssert not desc.ctx.isNil
  doAssert not bcSyncRef.isNil
  desc.ctx.pool.beaconSync = bcSyncRef
  if not desc.isRunning and
     # Re-start  beacon sync in server mode.
     bcSyncRef.start(standBy=true):
    # The `resetSync()` directive prevents from accidential re-initialising
    # after shut down. This has no effect on the first `starSynct()` call.
    discard desc.resetSync()
    if desc.startSync():
      return true
  # false

proc stop*(desc: SnapSyncRef) {.async.} =
  doAssert not desc.ctx.isNil
  await desc.stopSync()
  desc.ctx.pool.reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
