# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[base64, times, strutils],
  eth/common,
  nimcrypto/[hmac],
  stew/byteutils,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  web3/engine_api,
  unittest2

import
  ../nimbus/rpc,
  ../nimbus/config,
  ../nimbus/core/chain,
  ../nimbus/core/tx_pool,
  ../nimbus/beacon/beacon_engine,
  ../nimbus/beacon/web3_eth_conv,
  ../hive_integration/nodocker/engine/engine_client

type
  TestEnv* = ref object
    com    : CommonRef
    server : RpcHttpServer
    client : RpcHttpClient
    chain  : ForkedChainRef

const
  genesisFile = "tests/customgenesis/engine_api_genesis.json"

proc setupConfig(): NimbusConf =
  makeConfig(@[
    "--custom-network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

proc setupCom(conf: NimbusConf): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    conf.networkId,
    conf.networkParams
  )

proc setupClient(port: Port): RpcHttpClient =
  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", port, false)
  return client

proc setupEnv(): TestEnv =
  let
    conf  = setupConfig()
    com   = setupCom(conf)
    head  = com.db.getCanonicalHead()
    chain = newForkedChain(com, head)
    txPool = TxPoolRef.new(com)

  # txPool must be informed of active head
  # so it can know the latest account state
  doAssert txPool.smartHead(head, chain)

  let
    server = newRpcHttpServerWithParams("127.0.0.1:0").valueOr:
      echo "Failed to create rpc server: ", error
      quit(QuitFailure)
    beaconEngine = BeaconEngineRef.new(txPool, chain)
    serverApi = newServerAPI(chain)

  setupServerAPI(serverApi, server)
  setupEngineAPI(beaconEngine, server)

  server.start()

  let
    client = setupClient(server.localAddress[0].port)

  TestEnv(
    com    : com,
    server : server,
    client : client,
    chain  : chain,
  )

proc close(env: TestEnv) =
  waitFor env.client.close()
  waitFor env.server.closeWait()

proc runTest(env: TestEnv): Result[void, string] =
  let
    client = env.client
    header = ? client.latestHeader()
    update = ForkchoiceStateV1(
      headBlockHash: w3Hash header.blockHash
    )
    time = getTime().toUnix
    attr = PayloadAttributes(
      timestamp:             w3Qty(time + 1),
      prevRandao:            w3PrevRandao(),
      suggestedFeeRecipient: w3Address(),
      withdrawals:           Opt.some(newSeq[WithdrawalV1]()),
    )
    fcuRes = ? client.forkchoiceUpdated(Version.V1, update, Opt.some(attr))
    payload = ? client.getPayload(fcuRes.payloadId.get, Version.V1)
    npRes = ? client.newPayload(Version.V1, payload.executionPayload)
    res = ? client.forkchoiceUpdated(Version.V1, ForkchoiceStateV1(
      headBlockHash: npRes.latestValidHash.get
    ))
    bn = ? client.blockNumber()

  if bn != 1:
    return err("Expect returned block number: 1, got: " & $bn)
  
  ok()

proc engineApiMain*() =
  suite "Engine API":
    test "Basic cycle":
      let env = setupEnv()
      let res = env.runTest()
      if res.isErr:
        debugEcho "FAILED TO EXECUTE TEST: ", res.error
      check res.isOk
      env.close()

when isMainModule:
  engineApiMain()
