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
  std/times,
  eth/common,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  web3/engine_api,
  web3/conversions,
  web3/execution_types,
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
  TestEnv = ref object
    com    : CommonRef
    server : RpcHttpServer
    client : RpcHttpClient
    chain  : ForkedChainRef

  NewPayloadV4Params* = object
    payload*: ExecutionPayload
    expectedBlobVersionedHashes*: Opt[seq[Hash32]]
    parentBeaconBlockRoot*: Opt[Hash32]
    executionRequests*: Opt[array[3, seq[byte]]]

  TestSpec = object
    name: string
    fork: HardFork
    genesisFile: string
    testProc: proc(env: TestEnv): Result[void, string]

NewPayloadV4Params.useDefaultSerializationIn JrpcConv

const
  defaultGenesisFile = "tests/customgenesis/engine_api_genesis.json"
  mekongGenesisFile = "tests/customgenesis/mekong.json"

proc setupConfig(genesisFile: string): NimbusConf =
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

proc setupEnv(envFork: HardFork = MergeFork,
              genesisFile: string = defaultGenesisFile): TestEnv =
  doAssert(envFork >= MergeFork)

  let
    conf  = setupConfig(genesisFile)

  if envFork >= Shanghai:
    conf.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    conf.networkParams.config.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    conf.networkParams.config.pragueTime = Opt.some(0.EthTime)

  let
    com   = setupCom(conf)
    head  = com.db.getCanonicalHead()
    chain = ForkedChainRef.init(com)
    txPool = TxPoolRef.new(com)

  # txPool must be informed of active head
  # so it can know the latest account state
  doAssert txPool.smartHead(head, chain)

  let
    server = newRpcHttpServerWithParams("127.0.0.1:0").valueOr:
      echo "Failed to create rpc server: ", error
      quit(QuitFailure)
    beaconEngine = BeaconEngineRef.new(txPool, chain)
    serverApi = newServerAPI(chain, txPool)

  setupServerAPI(serverApi, server, newEthContext())
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

proc runBasicCycleTest(env: TestEnv): Result[void, string] =
  let
    client = env.client
    header = ? client.latestHeader()
    update = ForkchoiceStateV1(
      headBlockHash: header.blockHash
    )
    time = getTime().toUnix
    attr = PayloadAttributes(
      timestamp:             w3Qty(time + 1),
      prevRandao:            default(Bytes32),
      suggestedFeeRecipient: default(Address),
      withdrawals:           Opt.some(newSeq[WithdrawalV1]()),
    )
    fcuRes = ? client.forkchoiceUpdated(Version.V1, update, Opt.some(attr))
    payload = ? client.getPayload(Version.V1, fcuRes.payloadId.get)
    npRes = ? client.newPayloadV1(payload.executionPayload)

  discard ? client.forkchoiceUpdated(Version.V1, ForkchoiceStateV1(
    headBlockHash: npRes.latestValidHash.get
  ))
  let bn = ? client.blockNumber()

  if bn != 1:
    return err("Expect returned block number: 1, got: " & $bn)

  ok()

proc runNewPayloadV4Test(env: TestEnv): Result[void, string] =
  let
    client = env.client
    header = ? client.latestHeader()
    update = ForkchoiceStateV1(
      headBlockHash: header.blockHash
    )
    time = getTime().toUnix
    attr = PayloadAttributes(
      timestamp:             w3Qty(time + 1),
      prevRandao:            default(Bytes32),
      suggestedFeeRecipient: default(Address),
      withdrawals:           Opt.some(newSeq[WithdrawalV1]()),
      parentBeaconBlockRoot: Opt.some(default(Hash32))
    )
    fcuRes = ? client.forkchoiceUpdated(Version.V3, update, Opt.some(attr))
    payload = ? client.getPayload(Version.V4, fcuRes.payloadId.get)
    res = ? client.newPayloadV4(payload.executionPayload,
      Opt.some(default(seq[Hash32])),
      attr.parentBeaconBlockRoot,
      payload.executionRequests)

  if res.status != PayloadExecutionStatus.valid:
    return err("res.status should equals to PayloadExecutionStatus.valid")

  if res.latestValidHash.isNone or
     res.latestValidHash.get != payload.executionPayload.blockHash:
    return err("lastestValidHash mismatch")

  if res.validationError.isSome:
    return err("validationError should empty")

  ok()

proc newPayloadV4ParamsTest(env: TestEnv): Result[void, string] =
  const
    paramsFile = "tests/engine_api/newPayloadV4_invalid_blockhash.json"

  let
    client = env.client
    params = JrpcConv.loadFile(paramsFile, NewPayloadV4Params)
    res = ? client.newPayloadV4(
      params.payload,
      params.expectedBlobVersionedHashes,
      params.parentBeaconBlockRoot,
      params.executionRequests)

  if res.status != PayloadExecutionStatus.syncing:
    return err("res.status should equals to PayloadExecutionStatus.syncing")

  if res.latestValidHash.isSome:
    return err("lastestValidHash should empty")

  if res.validationError.isSome:
    return err("validationError should empty")

  ok()

proc genesisShouldCanonicalTest(env: TestEnv): Result[void, string] =
  const
    paramsFile = "tests/engine_api/genesis_base_canonical.json"

  let
    client = env.client
    params = JrpcConv.loadFile(paramsFile, NewPayloadV4Params)
    res = ? client.newPayloadV3(
      params.payload,
      params.expectedBlobVersionedHashes,
      params.parentBeaconBlockRoot)

  if res.status != PayloadExecutionStatus.valid:
    return err("res.status should equals to PayloadExecutionStatus.valid")

  if res.latestValidHash.isNone:
    return err("lastestValidHash should not empty")

  let
    update = ForkchoiceStateV1(
      headBlockHash: params.payload.blockHash,
      safeBlockHash: params.payload.parentHash,
      finalizedBlockHash: params.payload.parentHash,
    )
    fcuRes = ? client.forkchoiceUpdated(Version.V3, update)

  if fcuRes.payloadStatus.status != PayloadExecutionStatus.valid:
    return err("fcuRes.payloadStatus.status should equals to PayloadExecutionStatus.valid")

  ok()

const testList = [
  TestSpec(
    name: "Basic cycle",
    fork: MergeFork,
    testProc: runBasicCycleTest
  ),
  TestSpec(
    name: "newPayloadV4",
    fork: Prague,
    testProc: runNewPayloadV4Test
  ),
  TestSpec(
    name: "newPayloadV4 params",
    fork: Prague,
    testProc: newPayloadV4ParamsTest
  ),
  TestSpec(
    name: "Genesis block hash should canonical",
    fork: Cancun,
    testProc: genesisShouldCanonicalTest,
    genesisFile: mekongGenesisFile
  ),
  ]

proc engineApiMain*() =
  suite "Engine API":
    for z in testList:
      test z.name:
        let genesisFile = if z.genesisFile.len > 0:
                            z.genesisFile
                          else:
                            defaultGenesisFile
        let env = setupEnv(z.fork, genesisFile)
        let res = z.testProc(env)
        if res.isErr:
          debugEcho "FAILED TO EXECUTE ", z.name, ": ", res.error
        check res.isOk
        env.close()

when isMainModule:
  engineApiMain()
