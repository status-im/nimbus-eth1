# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronos,
  chronicles,
  ./networking/p2p,
  metrics/chronos_httpserver,
  ./rpc/rpc_server,
  ./core/chain,
  ./core/tx_pool,
  ./sync/peers,
  ./sync/beacon as beacon_sync,
  ./sync/snap as snap_sync,
  ./sync/wire_protocol,
  ./beacon/beacon_engine,
  ./common,
  json_rpc/rpcchannels

when enabledLogLevel == TRACE:
  import std/sequtils

export
  chronos,
  p2p,
  chronos_httpserver,
  rpc_server,
  chain,
  tx_pool,
  peers,
  beacon_sync,
  snap_sync,
  beacon_engine,
  common

type
  NimbusNode* = ref object
    httpServer*: NimbusHttpServerRef
    engineApiServer*: NimbusHttpServerRef
    engineApiChannel*: RpcChannelServer
    ethNode*: EthereumNode
    fc*: ForkedChainRef
    txPool*: TxPoolRef
    peerManager*: PeerManagerRef
    beaconSyncRef*: BeaconSyncRef
    snapSyncRef*: SnapSyncRef
    beaconEngine*: BeaconEngineRef
    ethWire*: EthWireRef
    snapWire*: SnapWireStateRef
    accountsManager*: ref AccountsManager
    rng*: ref HmacDrbgContext

proc closeWait*(nimbus: NimbusNode) {.async.} =
  trace "Graceful shutdown"
  var waitedFutures: seq[Future[void]]
  if nimbus.httpServer.isNil.not:
    waitedFutures.add nimbus.httpServer.stop()
  if nimbus.engineApiServer.isNil.not:
    waitedFutures.add nimbus.engineApiServer.stop()
  if nimbus.ethNode.isNil.not:
    waitedFutures.add nimbus.ethNode.closeWait()
  if nimbus.peerManager.isNil.not:
    waitedFutures.add nimbus.peerManager.stop()
  if nimbus.snapSyncRef.isNil.not:
    waitedFutures.add nimbus.snapSyncRef.stop()
  if nimbus.snapWire.isNil.not:
    waitedFutures.add nimbus.snapWire.stop()
  if nimbus.beaconSyncRef.isNil.not:
    waitedFutures.add nimbus.beaconSyncRef.stop()
  if nimbus.ethWire.isNil.not:
    waitedFutures.add nimbus.ethWire.stop()

  waitedFutures.add nimbus.fc.stopProcessingQueue()

  let
    timeout = chronos.seconds(5)
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Nimbus.stop(): timeout reached", timeout,
      futureErrors = waitedFutures.filterIt(it.error != nil).mapIt(it.error.msg)

{.pop.}
