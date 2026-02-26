# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  ./beacon/worker/classify,
  ./[sync_sched, wire_protocol]

export
  beacon_desc

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc addBeaconSyncProtocol(desc: BeaconSyncRef; PROTO: type) =
  ## Add protocol and call back filter & init functions for ethXX
  proc acceptPeer(peer: Peer): bool =
    peer.state(PROTO).initialized

  proc initWorker(worker: SyncPeerRef[BeaconCtxData,BeaconPeerData]) =
    when PROTO is eth68:
      worker.only.pivotHash = worker.peer.state(PROTO).bestHash
    elif PROTO is eth69:
      worker.only.pivotHash = worker.peer.state(PROTO).latestHash
    elif PROTO is eth70:
      worker.only.pivotHash = worker.peer.state(PROTO).latestHash
    else:
      {.error: "Unsupported eth/?? version".}

  desc.addSyncProtocol(PROTO, acceptPeer, initWorker)

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  worker.setup(ctx, "Setup")

proc runRelease(ctx: BeaconCtxRef) =
  worker.release(ctx, "Release")

proc runDaemon(ctx: BeaconCtxRef): Future[Duration] {.async: (raises: []).} =
  return worker.runDaemon(ctx, "Daemon")

proc runTicker(ctx: BeaconCtxRef) =
  worker.runTicker(ctx, "Ticker")

proc runStart(buddy: BeaconPeerRef): bool =
  worker.start(buddy, "Start")

proc runStop(buddy: BeaconPeerRef) =
  worker.stop(buddy, "Stop")

proc runPool(buddy: BeaconPeerRef; last: bool; laps: int): bool =
  worker.runPool(buddy, last, laps, "SyncMode")

proc runPeer(buddy: BeaconPeerRef): Future[Duration] {.async: (raises: []).} =
  let rank = buddy.classifyForFetching()
  return worker.runPeer(buddy, rank, "Peer")

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
      ) =
  ## Complete `BeaconSyncRef` descriptor initialisation.
  ##
  ## If the `snap` protocol is used as well, the argument `latestOnly` must be
  ## set `true`. There can only be one active `eth` protocol version assuming
  ## that the number of messages differ with the `eth` versions. Due to tight
  ## packaging of message IDs, different `eth` protocol lengths lead to varying
  ## `snap` message IDs depending on the `eth` version. To handle this is
  ## currently unsupported.
  ##
  ## Note that the `init()` constructor might have specified a configuration
  ## task to be run at the end of the `config()` function.
  ##
  doAssert desc.ctx.isNil # This can only run once
  desc.initSync(ethNode, maxPeers)

  # The registration order for protocols is largely irrelevant, yet the first
  # will always be compared with the activated protocol which is likely to be
  # expected the latest version of the `eth` protocol family.
  desc.addBeaconSyncProtocol(eth70)
  desc.addBeaconSyncProtocol(eth69)
  desc.addBeaconSyncProtocol(eth68)

  desc.ctx.pool.chain = chain

  if not desc.lazyConfigHook.isNil:
    desc.lazyConfigHook(desc)
    desc.lazyConfigHook = nil

proc configTarget*(desc: BeaconSyncRef; hex: string; isFinal: bool): bool =
  ## Set up inital target sprint (if any, mainly for debugging)
  doAssert not desc.ctx.isNil
  try:
    desc.ctx.headersTargetRequest(Hash32.fromHex(hex), isFinal, "init")
    return true
  except ValueError:
    discard
  # false

# -----------------

proc start*(desc: BeaconSyncRef; standBy = false): bool =
  ## This function returns `true` exactly if the run state could be changed.
  ## The following expressions are equivalent:
  ## * desc.start(true)
  ## * desc.start(false) and desc.start(true)
  ##
  doAssert not desc.ctx.isNil
  let save = desc.ctx.pool.standByMode
  desc.ctx.pool.standByMode = standBy # the ticker sees this when starting
  if desc.startSync(standBy):
    return true
  desc.ctx.pool.standByMode = save
  # false

proc stop*(desc: BeaconSyncRef) {.async.} =
  doAssert not desc.ctx.isNil
  if desc.isRunning:
    await desc.stopSync()
    desc.ctx.pool.reset # also clears stand-by mode

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
