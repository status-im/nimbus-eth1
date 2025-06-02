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
  ./beacon/[beacon_desc, worker],
  ./beacon/worker/blocks/[blocks_fetch, blocks_import],
  ./beacon/worker/headers/[headers_fetch, headers_target],
  ./beacon/worker/[classify, update],
  ./[sync_sched, wire_protocol]

export
  beacon_desc

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc addBeaconSyncProtocol(desc: BeaconSyncRef; PROTO: type) =
  ## Add protocol and call back filter function for ethXX
  proc acceptPeer(peer: Peer): bool =
    let state = peer.state(PROTO)
    not state.isNil and state.initialized

  proc initWorker(worker: SyncPeerRef[BeaconCtxData,BeaconPeerData]) =
    when PROTO is eth68:
      worker.only.pivotHash = worker.peer.state(PROTO).bestHash
    elif PROTO is eth69:
      worker.only.pivotHash = worker.peer.state(PROTO).latestHash
    else:
      {.error: "Unsupported eth/?? version".}

  desc.addSyncProtocol(PROTO, acceptPeer, initWorker)

# ------------------------------------------------------------------------------
# Interceptable handlers
# ------------------------------------------------------------------------------

proc schedDaemonCB(
    ctx: BeaconCtxRef;
      ): Future[Duration]
      {.async: (raises: []).} =
  return worker.runDaemon(ctx, "Daemon") # async/template

proc schedStartCB(buddy: BeaconPeerRef): bool =
  return worker.start(buddy, "Start")

proc schedStopCB(buddy: BeaconPeerRef) =
  worker.stop(buddy, "Stop")

proc schedPoolCB(buddy: BeaconPeerRef; last: bool; laps: int): bool =
  return worker.runPool(buddy, last, laps, "SyncMode")

proc schedPeerCB(
    buddy: BeaconPeerRef;
    rank: PeerRanking;
      ): Future[Duration]
      {.async: (raises: []).} =
  return worker.runPeer(buddy, rank, "Peer") # async/template

proc noOpFn(buddy: BeaconPeerRef) = discard
proc noOpEx(self: BeaconHandlersSyncRef) = discard

# ------------------------------------------------------------------------------
# Virtual methods/interface, `mixin` functions
# ------------------------------------------------------------------------------

proc runSetup(ctx: BeaconCtxRef): bool =
  return worker.setup(ctx, "Setup")

proc runRelease(ctx: BeaconCtxRef) =
  worker.release(ctx, "Release")

proc runTicker(ctx: BeaconCtxRef) =
  worker.runTicker(ctx, "Ticker")


proc runDaemon(ctx: BeaconCtxRef): Future[Duration] {.async: (raises: []).} =
  return await ctx.handler.schedDaemon(ctx)

proc runStart(buddy: BeaconPeerRef): bool =
  return buddy.ctx.handler.schedStart(buddy)

proc runStop(buddy: BeaconPeerRef) =
  buddy.ctx.handler.schedStop(buddy)

proc runPool(buddy: BeaconPeerRef; last: bool; laps: int): bool =
  return buddy.ctx.handler.schedPool(buddy, last, laps)

proc runPeer(buddy: BeaconPeerRef): Future[Duration] {.async: (raises: []).} =
  let rank = buddy.classifyForFetching()
  return await buddy.ctx.handler.schedPeer(buddy, rank)

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
    latestOnly = false;
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

  # Add most likely/highest priority protocol first. As of the current
  # implementation, `eth68` descriptor(s) will not be fully initialised
  # (i.e. `peer.state(eth68).isNil`) if `eth69` is available.
  desc.addBeaconSyncProtocol(eth69)
  if not latestOnly:
    desc.addBeaconSyncProtocol(eth68)

  desc.ctx.pool.chain = chain

  # Set up handlers so they can be overlayed
  desc.ctx.pool.handlers = BeaconHandlersSyncRef(
    version:          0,
    activate:         updateActivateCB,
    suspend:          updateSuspendCB,
    schedDaemon:      schedDaemonCB,
    schedStart:       schedStartCB,
    schedStop:        schedStopCB,
    schedPool:        schedPoolCB,
    schedPeer:        schedPeerCB,
    getBlockHeaders:  getBlockHeadersCB,
    syncBlockHeaders: noOpFn,
    getBlockBodies:   getBlockBodiesCB,
    syncBlockBodies:  noOpFn,
    importBlock:      importBlockCB,
    syncImportBlock:  noOpFn,
    startSync:        noOpEx,
    stopSync:         noOpEx)

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
  if desc.isRunning:
    if desc.startSync(standBy):
      return true
  elif desc.startSync(standBy):
    let w = BeaconHandlersSyncRef(desc.ctx.pool.handlers)
    w.startSync(w)
    return true
  desc.ctx.pool.standByMode = save
  # false

proc stop*(desc: BeaconSyncRef) {.async.} =
  doAssert not desc.ctx.isNil
  if desc.isRunning:
    let w = BeaconHandlersSyncRef(desc.ctx.pool.handlers)
    w.stopSync(w)
    await desc.stopSync()
    desc.ctx.pool.reset # also clears stand-by mode

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
