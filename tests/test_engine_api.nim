# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ../execution_chain/rpc,
  ../execution_chain/conf,
  ../execution_chain/core/chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/beacon/beacon_engine,
  ../execution_chain/beacon/web3_eth_conv,
  ../hive_integration/engine_client

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
    executionRequests*: Opt[seq[seq[byte]]]

  TestSpec = object
    name: string
    fork: HardFork
    genesisFile: string
    testProc: proc(env: TestEnv): Result[void, string]

NewPayloadV4Params.useDefaultSerializationIn JrpcConv

const
  defaultGenesisFile = "tests/customgenesis/engine_api_genesis.json"
  mekongGenesisFile = "tests/customgenesis/mekong.json"

proc setupConfig(genesisFile: string): ExecutionClientConf =
  makeConfig(@[
    "--network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

proc setupCom(config: ExecutionClientConf): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    nil,
    config.networkId,
    config.networkParams
  )

proc setupClient(port: Port): RpcHttpClient =
  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", port, false)
  return client

proc setupEnv(envFork: HardFork = MergeFork,
              genesisFile: string = defaultGenesisFile): TestEnv =
  doAssert(envFork >= MergeFork)

  let
    config  = setupConfig(genesisFile)

  if envFork >= Shanghai:
    config.networkParams.config.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    config.networkParams.config.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    config.networkParams.config.pragueTime = Opt.some(0.EthTime)

  let
    com   = setupCom(config)
    chain = ForkedChainRef.init(com, enableQueue = true)
    txPool = TxPoolRef.new(chain)

  let
    server = newRpcHttpServerWithParams("127.0.0.1:0").valueOr:
      echo "Failed to create rpc server: ", error
      quit(QuitFailure)
    beaconEngine = BeaconEngineRef.new(txPool)
    serverApi = newServerAPI(txPool)

  setupServerAPI(serverApi, server, new AccountsManager)
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
  waitFor env.chain.stopProcessingQueue()

proc runBasicCycleTest(env: TestEnv): Result[void, string] =
  let
    client = env.client
    header = ? client.latestHeader()
    update = ForkchoiceStateV1(
      headBlockHash: header.computeBlockHash
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
      headBlockHash: header.computeBlockHash
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
    paramsFiles = [
      "tests/engine_api/newPayloadV4_invalid_blockhash.json",
      "tests/engine_api/newPayloadV4_requests_order.json"
    ]

  for paramsFile in paramsFiles:
    let
      client = env.client
      params = JrpcConv.loadFile(paramsFile, NewPayloadV4Params)
      res = ?client.newPayloadV4(
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

proc newPayloadV4InvalidRequests(env: TestEnv): Result[void, string] =
  const
    paramsFiles = [
      "tests/engine_api/newPayloadV4_invalid_requests.json",
      "tests/engine_api/newPayloadV4_empty_requests_data.json",
      "tests/engine_api/newPayloadV4_invalid_requests_order.json",
    ]

  for paramsFile in paramsFiles:
    let
      client = env.client
      params = JrpcConv.loadFile(paramsFile, NewPayloadV4Params)
      res = client.newPayloadV4(
        params.payload,
        params.expectedBlobVersionedHashes,
        params.parentBeaconBlockRoot,
        params.executionRequests)

    if res.isOk:
      return err("res should error")

    if $engineApiInvalidParams notin res.error:
      return err("invalid error code: " & res.error & " expect: " & $engineApiInvalidParams)

    if "request" notin res.error:
      return err("expect \"request\" in error message: " & res.error)

  ok()

proc newPayloadV4InvalidRequestType(env: TestEnv): Result[void, string] =
  const
    paramsFile = "tests/engine_api/newPayloadV4_invalid_requests_type.json"

  let
    client = env.client
    params = JrpcConv.loadFile(paramsFile, NewPayloadV4Params)
    res = client.newPayloadV4(
      params.payload,
      params.expectedBlobVersionedHashes,
      params.parentBeaconBlockRoot,
      params.executionRequests)

  if res.isErr:
    return err("res should success")

  if res.get.status != PayloadExecutionStatus.invalid:
    return err("res.status should be equal to PayloadExecutionStatus.invalid")

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
  TestSpec(
    name: "newPayloadV4 invalid execution requests",
    fork: Prague,
    testProc: newPayloadV4InvalidRequests
  ),
  TestSpec(
    name: "newPayloadV4 invalid execution request type",
    fork: Prague,
    testProc: newPayloadV4InvalidRequestType
  ),
  ]

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
