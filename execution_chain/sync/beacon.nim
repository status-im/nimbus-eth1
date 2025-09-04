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
  ./beacon/worker/headers/headers_target,
  ./beacon/[beacon_desc, worker],
  ./[sync_sched, wire_protocol]

export
  beacon_desc

logScope:
  topics = "beacon sync"

var beaconSyncConfigHook = BeaconSyncConfigHook(nil)
  ## Optional configuration request hook. This must be initialised before
  ## the `BeaconSyncRef.init()` constructor is called to be effective.

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  worker.setup(ctx, "RunSetup")

proc runRelease(ctx: BeaconCtxRef) =
  worker.release(ctx, "RunRelease")

proc runDaemon(ctx: BeaconCtxRef): Future[Duration] {.async: (raises: []).} =
  return worker.runDaemon(ctx, "RunDaemon")

proc runTicker(ctx: BeaconCtxRef) =
  worker.runTicker(ctx, "RunTicker")

proc runStart(buddy: BeaconBuddyRef): bool =
  worker.start(buddy, "RunStart")

proc runStop(buddy: BeaconBuddyRef) =
  worker.stop(buddy, "RunStop")

proc runPool(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps, "RunPool")

proc runPeer(buddy: BeaconBuddyRef): Future[Duration] {.async: (raises: []).} =
  return worker.runPeer(buddy, "RunPeer")

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc config*(
    _: type BeaconSyncRef;
    configCB: BeaconSyncConfigHook;
      ): BeaconSyncConfigHook =
  ## Set config hook to be run by the `BeaconSyncRef.init()` constructor
  ## request. If activated, it will alse make `shouldRun()` return `true`.
  ## The function returns the previous hook if there was any, or `nil`.
  ##
  var oldHook = beaconSyncConfigHook
  beaconSyncConfigHook = configCB
  move oldHook

proc init*(
    T: type BeaconSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
    haveEngine: bool;
      ): T =
  var desc = T()
  desc.initSync(ethNode, maxPeers)
  desc.ctx.pool.chain = chain
  desc.ctx.shouldRun = (0 < maxPeers and haveEngine)

  if not beaconSyncConfigHook.isNil:
    beaconSyncConfigHook(desc)
    beaconSyncConfigHook = nil
    desc.ctx.shouldRun = true

  desc

proc shouldRun*(desc: BeaconSyncRef): bool =
  ## Getter
  desc.ctx.shouldRun

proc targetInit*(desc: BeaconSyncRef; hex: string; isFinal: bool): bool =
  ## Set up inital target sprint (if any, mainly for debugging)
  try:
    desc.ctx.headersTargetRequest(Hash32.fromHex(hex), isFinal, "init")
    desc.ctx.shouldRun = true
    return true
  except ValueError:
    discard
  # false

proc start*(desc: BeaconSyncRef): bool =
  desc.startSync()

proc stop*(desc: BeaconSyncRef) {.async.} =
  await desc.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
