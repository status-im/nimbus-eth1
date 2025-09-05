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

proc init*(
    T: type BeaconSyncRef;
    configCB = BeaconSyncConfigHook(nil);
      ): T =
  ## Constructor
  ##
  ## The `configCB` allows to specify a final configuration task to be run at
  ## the end of the `config()` function.
  ##
  T(lazyConfigHook: configCB)

proc config*(
    desc: BeaconSyncRef;
    ethNode: EthereumNode;
    chain: ForkedChainRef;
    maxPeers: int;
    haveEngine: bool;
      ) =
  ## Complete `BeaconSyncRef` descriptor initialisation.
  ##
  ## Note that the `init()` constructor might have specified a configuration
  ## task to be run at the end of the `config()` function.
  ##
  doAssert desc.ctx.isNil # This can only run once
  desc.initSync(ethNode, maxPeers)
  desc.ctx.pool.chain = chain
  desc.ctx.shouldRun = (0 < maxPeers and haveEngine)

  if not desc.lazyConfigHook.isNil:
    desc.lazyConfigHook(desc)
    desc.lazyConfigHook = nil
    desc.ctx.shouldRun = true

proc shouldRun*(desc: BeaconSyncRef): bool =
  ## Getter
  desc.ctx.shouldRun

proc targetInit*(desc: BeaconSyncRef; hex: string; isFinal: bool): bool =
  ## Set up inital target sprint (if any, mainly for debugging)
  doAssert not desc.ctx.isNil
  try:
    desc.ctx.headersTargetRequest(Hash32.fromHex(hex), isFinal, "init")
    desc.ctx.shouldRun = true
    return true
  except ValueError:
    discard
  # false

proc start*(desc: BeaconSyncRef): bool =
  doAssert not desc.ctx.isNil
  desc.startSync()

proc stop*(desc: BeaconSyncRef) {.async.} =
  doAssert not desc.ctx.isNil
  await desc.stopSync()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
