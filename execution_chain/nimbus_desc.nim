# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos,
  ./networking/p2p,
  metrics/chronos_httpserver,
  ./rpc/rpc_server,
  ./core/chain,
  ./core/tx_pool,
  ./sync/peers,
  ./sync/beacon as beacon_sync,
  ./beacon/beacon_engine,
  ./common,
  ./config

export
  chronos,
  p2p,
  chronos_httpserver,
  rpc_server,
  chain,
  tx_pool,
  peers,
  beacon_sync,
  beacon_engine,
  common,
  config

type
  NimbusState* = enum
    Starting, Running, Stopping

  NimbusNode* = ref object
    httpServer*: NimbusHttpServerRef
    engineApiServer*: NimbusHttpServerRef
    ethNode*: EthereumNode
    state*: NimbusState
    ctx*: EthContext
    fc*: ForkedChainRef
    txPool*: TxPoolRef
    networkLoop*: Future[void]
    peerManager*: PeerManagerRef
    beaconSyncRef*: BeaconSyncRef
    beaconEngine*: BeaconEngineRef
    metricsServer*: MetricsHttpServerRef

{.push gcsafe, raises: [].}

proc stop*(nimbus: NimbusNode, conf: NimbusConf) {.async, gcsafe.} =
  trace "Graceful shutdown"
  if nimbus.httpServer.isNil.not:
    await nimbus.httpServer.stop()
  if nimbus.engineApiServer.isNil.not:
    await nimbus.engineApiServer.stop()
  if nimbus.beaconSyncRef.isNil.not:
    await nimbus.beaconSyncRef.stop()
  if conf.maxPeers > 0:
    await nimbus.networkLoop.cancelAndWait()
  if nimbus.peerManager.isNil.not:
    await nimbus.peerManager.stop()
  if nimbus.metricsServer.isNil.not:
    await nimbus.metricsServer.stop()

{.pop.}
