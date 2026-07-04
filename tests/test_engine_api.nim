# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
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
  eth/common/keys,
  ../execution_chain/rpc,
  ../execution_chain/conf,
  ../execution_chain/common,
  ../execution_chain/transaction,
  ../execution_chain/core/chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/beacon/beacon_engine,
  ../execution_chain/beacon/web3_eth_conv,
  ../hive_integration/engine_client,
   ./shared_data/eip8282data

type
  TestEnv = ref object
    com    : CommonRef
    server : RpcHttpServer
    client : RpcHttpClient
    chain  : ForkedChainRef
    txPool : TxPoolRef

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

NewPayloadV4Params.useDefaultSerializationIn EthJson

const
  defaultGenesisFile = "tests/customgenesis/engine_api_genesis.json"
  mekongGenesisFile = "tests/customgenesis/mekong.json"
  wdAddress = address"0xf6c3a9edc1afa0ad5b720e4d42e1437c43d3b3ff"

let
  # Deterministic test signer, funded in the default genesis (see setupEnv) so
  # that a valid transaction can be injected into the tx pool.
  testSenderKey = PrivateKey.fromHex(
    "0x4646464646464646464646464646464646464646464646464646464646464646").expect(
    "valid private key")
  testSender = testSenderKey.toPublicKey().to(Address)

proc setupConfig(genesisFile: string): ExecutionClientConf =
  makeConfig(@[
    "--network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

proc setupCom(config: ExecutionClientConf): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
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

  if envFork >= Osaka:
    config.networkParams.config.osakaTime = Opt.some(0.EthTime)

  if envFork >= Amsterdam:
    config.networkParams.config.bpo1Time = Opt.some(0.EthTime)
    config.networkParams.config.bpo2Time = Opt.some(0.EthTime)
    config.networkParams.config.amsterdamTime = Opt.some(0.EthTime)
    config.networkParams.genesis.alloc[BUILDER_DEPOSIT_CONTRACT_ADDRESS] = GenesisAccount(code: builderDepositRequestCode)
    config.networkParams.genesis.alloc[BUILDER_EXIT_CONTRACT_ADDRESS] = GenesisAccount(code: builderExitRequestCode)

  # Fund the test signer only for the default genesis, so tests that rely on a
  # fixed genesis/block hash (e.g. the mekong canonical test) are unaffected.
  if genesisFile == defaultGenesisFile:
    config.networkParams.genesis.alloc[testSender] =
      GenesisAccount(balance: 1_000_000_000_000_000_000.u256)
    config.networkParams.genesis.alloc[wdAddress] =
      GenesisAccount(balance: 1_000_000_000_000_000_000.u256)

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
    txPool : txPool,
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

proc makeSignedTx(env: TestEnv, nonce: AccountNonce = 0): Transaction =
  # A valid, includable legacy tx from the funded test signer.
  let tx = Transaction(
    txType:   TxLegacy,
    chainId:  env.com.chainId,
    nonce:    nonce,
    gasPrice: 30_000_000_000.GasInt,
    gasLimit: 70_000.GasInt,
    to:       Opt.some(default(Address)),
    value:    1.u256,
  )
  signTransaction(tx, testSenderKey, eip155 = true)

proc runPayloadRebuildTest(env: TestEnv): Result[void, string] =
  # Calling forkchoiceUpdated repeatedly with identical payload attributes must
  # rebuild the payload from a fresh transaction environment each time. This
  # guards a regression where a rebuild for the same slot reused the previous
  # pack's dirtied ledger state: on the second build every pooled tx then failed
  # the nonce check, so the body came out empty, yet the header still committed
  # to the first pack's accumulators.
  #
  # We prove it by building the SAME payload twice from the SAME pool (several
  # includable txs sitting in it the whole time): both builds must produce the
  # identical, non-empty block, and newPayload must accept it as valid.
  const numTxs = 5
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

  # Seed the pool with several valid transactions (consecutive nonces) before
  # any build.
  for nonce in 0 ..< numTxs:
    env.txPool.addTx(env.makeSignedTx(nonce.AccountNonce)).isOkOr:
      return err("Failed to add tx " & $nonce & " to pool: " & $error)

  # First FCU: builds a payload that includes the pooled txs.
  let
    fcuRes1 = ? client.forkchoiceUpdated(Version.V1, update, Opt.some(attr))
    id1     = fcuRes1.payloadId.get
    payload1 = ? client.getPayload(Version.V1, id1)

  if payload1.executionPayload.transactions.len != numTxs:
    return err("Expected " & $numTxs & " txs in first build, got: " &
      $payload1.executionPayload.transactions.len)

  # Second FCU with the SAME attributes and the SAME pool: must rebuild from a
  # fresh state and again include every tx. If the second pack reused the first
  # pack's dirtied ledger, the txs would fail their nonce checks and the body
  # would come out empty.
  let
    fcuRes2 = ? client.forkchoiceUpdated(Version.V1, update, Opt.some(attr))
    id2     = fcuRes2.payloadId.get
    payload2 = ? client.getPayload(Version.V1, id2)

  if payload2.executionPayload.transactions.len != numTxs:
    return err("Rebuild dropped txs: expected " & $numTxs & " txs, got " &
      $payload2.executionPayload.transactions.len)

  # Same head, same attributes, same txs -> byte-identical block.
  if payload2.executionPayload.blockHash != payload1.executionPayload.blockHash:
    return err("Rebuilt block differs from first build: " &
      payload1.executionPayload.blockHash.toHex & " vs " &
      payload2.executionPayload.blockHash.toHex)

  # The rebuilt block must be self-consistent: newPayload validates the header's
  # gasUsed/stateRoot/receiptsRoot against the actual body, which would fail if
  # the header committed to a stale (empty-body) pack.
  let npRes = ? client.newPayloadV1(payload2.executionPayload)
  if npRes.status != PayloadExecutionStatus.valid:
    return err("Rebuilt block rejected by newPayload: " & $npRes.status &
      " err: " & npRes.validationError.get(""))

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
      params = EthJson.loadFile(paramsFile, NewPayloadV4Params)
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
    params = EthJson.loadFile(paramsFile, NewPayloadV4Params)
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
      params = EthJson.loadFile(paramsFile, NewPayloadV4Params)
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

proc newPayloadInvalidRLP(env: TestEnv): Result[void, string] =
  const paramsFile = "tests/engine_api/newPayload_invalid_rlp.json"

  let
    client = env.client
    params = EthJson.loadFile(paramsFile, NewPayloadV4Params)
    res = client.newPayloadV4(
      params.payload,
      params.expectedBlobVersionedHashes,
      params.parentBeaconBlockRoot,
      params.executionRequests)

  if res.isOk:
    return err("res should error on undecodable payload")

  if $engineApiInvalidParams notin res.error:
    return err("invalid error code: " & res.error &
      " expect: " & $engineApiInvalidParams)

  ok()

proc newPayloadV4InvalidRequestType(env: TestEnv): Result[void, string] =
  const
    paramsFile = "tests/engine_api/newPayloadV4_invalid_requests_type.json"

  let
    client = env.client
    params = EthJson.loadFile(paramsFile, NewPayloadV4Params)
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

proc payloadAttrV4PreserveWithdrawalsTest(env: TestEnv): Result[void, string] =
  # Regression: setWithdrawals used to drop withdrawals for V4 (Amsterdam) payload
  # attributes. A PayloadAttributes with a targetGasLimit resolves to Version.V4,
  # which fell into the `else` branch and had its withdrawals replaced with an empty
  # seq, so the assembled payload carried no withdrawals even when the attributes
  # requested some. Verify they are preserved.
  let
    client = env.client
    header = ? client.latestHeader()
    update = ForkchoiceStateV1(
      headBlockHash: header.computeBlockHash
    )
    time = getTime().toUnix
    wd = WithdrawalV1(
      index: w3Qty(0'u64),
      validatorIndex: w3Qty(0'u64),
      address: wdAddress,
      amount: w3Qty(7'u64),
    )
    attr = PayloadAttributes(
      timestamp:             w3Qty(time + 1),
      prevRandao:            default(Bytes32),
      suggestedFeeRecipient: default(Address),
      withdrawals:           Opt.some(@[wd]),
      parentBeaconBlockRoot: Opt.some(default(Hash32)),
      slotNumber:            Opt.some(w3Qty(0'u64)),
      targetGasLimit:        Opt.some(w3Qty(60_000_000'u64)),
    )

  let
    fcuRes  = ? client.forkchoiceUpdated(Version.V4, update, Opt.some(attr))
    id      = fcuRes.payloadId.get
    payload = ? client.getPayload(Version.V6, id)

  if payload.executionPayload.transactions.len != 0:
    return err("Expected empty payload before injecting tx, got: " &
      $payload.executionPayload.transactions.len & " txs")

  if payload.executionPayload.withdrawals.isNone:
    return err("Expected non empty withdrawals")

  let wds = payload.executionPayload.withdrawals.value
  if wds.len != 1:
    return err("Expected withdrawals len 1, got: " & $wds.len)

  if wds[0].amount.uint64 != 7:
    return err("Expected withdrawals[0].amount = 7, got : " & $wds[0].amount)

  if wds[0].address != wdAddress:
    return err("Expected withdrawals[0].address = " & $wdAddress &
      ", got : " & $wds[0].address)

  ok()

const testList = [
  TestSpec(
    name: "Basic cycle",
    fork: MergeFork,
    testProc: runBasicCycleTest
  ),
  TestSpec(
    name: "Payload rebuild for identical FCU",
    fork: MergeFork,
    testProc: runPayloadRebuildTest
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
  TestSpec(
    name: "newPayload undecodable RLP payload",
    fork: Prague,
    testProc: newPayloadInvalidRLP
  ),
  TestSpec(
    name: "PayloadAttributesV4 preserve withdrawals",
    fork: Amsterdam,
    testProc: payloadAttrV4PreserveWithdrawalsTest
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
