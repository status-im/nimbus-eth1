# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronos,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  ../../execution_chain/rpc,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ./eest_helpers

export
  eest_helpers

type
  RpcTestEnv* = ref object
    chain*: ForkedChainRef
    server*: Opt[RpcHttpServer]
    client*: Opt[RpcHttpClient]
    beaconEngine*: BeaconEngineRef

proc setupClient*(port: Port): RpcHttpClient =
  try:
    let client = newRpcHttpClient()
    waitFor client.connect("127.0.0.1", port, false)
    return client
  except CatchableError as exc:
    debugEcho "CONNECT ERROR: ", exc.msg
    quit(QuitFailure)

proc prepareRpcEnv*(
    unit: UnitEnv,
    genesis: Header,
    statelessEnabled = false,
    parallelEnabled = false,
): RpcTestEnv =
  try:
    let
      chain = newForkedChain(unit, genesis, statelessEnabled, parallelEnabled)
      txPool = TxPoolRef.new(chain)
      server = newRpcHttpServerWithParams("127.0.0.1:7717").valueOr:
        echo "Failed to create rpc server: ", error
        quit(QuitFailure)
      beaconEngine = BeaconEngineRef.new(txPool)
      serverApi = newServerAPI(txPool)

    setupServerAPI(serverApi, server, new AccountsManager)
    setupEngineAPI(beaconEngine, server)

    server.start()

    let client = setupClient(server.localAddress[0].port)

    RpcTestEnv(
      chain: chain,
      client: Opt.some(client),
      server: Opt.some(server),
      beaconEngine: beaconEngine,
    )
  except ValueError as exc:
    debugEcho "Prepare rpc env error: ", exc.msg
    quit(QuitFailure)

proc close*(env: RpcTestEnv) =
  try:
    if env.client.isSome:
      waitFor env.client.get().close()
    if env.server.isSome:
      waitFor env.server.get().closeWait()
    if env.beaconEngine.isNil.not:
      waitFor env.beaconEngine.stop()
    closeChain(env.chain)
  except CatchableError as exc:
    debugEcho "Close error: ", exc.msg
    quit(QuitFailure)
