# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, os, typetraits],
  unittest2,
  json_rpc/[rpcserver, rpcclient],
  web3/[engine_api_types, conversions],
  ../nimbus/sync/protocol,
  ../nimbus/rpc,
  ../nimbus/common,
  ../nimbus/config,
  ../nimbus/core/[sealer, tx_pool, chain],
  ../nimbus/beacon/[beacon_engine, payload_queue],
  ./test_helpers

const
  baseDir = "tests" / "merge"
  paramsFile = baseDir / "params.json"
  stepsFile = baseDir / "steps.json"

type
  StepObj = object
    name: string
    `method`: string
    params: JSonNode
    expect: JsonString
    error : JsonString

  Step = ref StepObj
  Steps = seq[Step]

StepObj.useDefaultSerializationIn JrpcConv

proc forkChoiceUpdate(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  let jsonBytes = waitFor client.call(step.`method`, step.params)
  let resA = JrpcConv.decode(jsonBytes.string, ForkchoiceUpdatedResponse)
  let resB = JrpcConv.decode(step.expect.string, ForkchoiceUpdatedResponse)
  check resA == resB

proc getPayload(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  try:
    let jsonBytes = waitFor client.call(step.`method`, step.params)
    let resA = JrpcConv.decode(jsonBytes.string, ExecutionPayloadV1)
    let resB = JrpcConv.decode(step.expect.string, ExecutionPayloadV1)
    check resA == resB
  except CatchableError:
    check step.error.string.len > 0

proc newPayload(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  let jsonBytes = waitFor client.call(step.`method`, step.params)
  let resA = JrpcConv.decode(jsonBytes.string, PayloadStatusV1)
  let resB = JrpcConv.decode(step.expect.string, PayloadStatusV1)
  check resA == resB

proc runTest(steps: Steps) =
  let
    conf = makeConfig(@["--custom-network:" & paramsFile])
    ctx  = newEthContext()
    ethNode = setupEthNode(conf, ctx, eth)
    com = CommonRef.new(
      newCoreDbRef LegacyDbMemory,
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chainRef = newChain(com)

  com.initializeEmptyDb()

  var
    rpcServer = newRpcSocketServer(["127.0.0.1:0"])
    client = newRpcSocketClient()
    txPool = TxPoolRef.new(com, conf.engineSigner)
    sealingEngine = SealingEngineRef.new(
      chainRef, ctx, conf.engineSigner,
      txPool, EnginePostMerge
    )
    beaconEngine = BeaconEngineRef.new(txPool, chainRef)

  setupEthRpc(ethNode, ctx, com, txPool, rpcServer)
  setupEngineAPI(beaconEngine, rpcServer)

  sealingEngine.start()
  rpcServer.start()
  waitFor client.connect(rpcServer.localAddress()[0])

  suite "Engine API tests":
    for i, step in steps:
      test $i & " " & step.name:
        case step.`method`
        of "engine_forkchoiceUpdatedV1":
          forkChoiceUpdate(step, client, testStatusIMPL)
        of "engine_getPayloadV1":
          getPayload(step, client, testStatusIMPL)
        of "engine_newPayloadV1":
          newPayload(step, client, testStatusIMPL)
        else:
          doAssert(false, "unknown method: " & step.`method`)

  waitFor sealingEngine.stop()
  rpcServer.stop()
  waitFor rpcServer.closeWait()

proc testEngineAPI() =
  let steps = JrpcConv.loadFile(stepsFile, Steps)
  runTest(steps)

proc toId(x: int): PayloadId =
  var id: distinctBase PayloadId
  id[^1] = x.byte
  PayloadId(id)

proc `==`(a, b: Quantity): bool =
  uint64(a) == uint64(b)

proc testEngineApiSupport() =
  var api = PayloadQueue()
  let
    id1 = toId(1)
    id2 = toId(2)
    ep1 = ExecutionPayloadV1(gasLimit: Quantity 100)
    ep2 = ExecutionPayloadV1(gasLimit: Quantity 101)
    hdr1 = common.BlockHeader(gasLimit: 100)
    hdr2 = common.BlockHeader(gasLimit: 101)
    hash1 = hdr1.blockHash
    hash2 = hdr2.blockHash

  suite "Test engine api support":
    test "test payload queue":
      api.put(id1, 123.u256, ep1)
      api.put(id2, 456.u256, ep2)
      var eep1, eep2: ExecutionPayloadV1
      var bv1, bv2: UInt256
      check api.get(id1, bv1, eep1)
      check api.get(id2, bv2, eep2)
      check eep1.gasLimit == ep1.gasLimit
      check eep2.gasLimit == ep2.gasLimit
      check bv1 == 123.u256
      check bv2 == 456.u256

    test "test header queue":
      api.put(hash1, hdr1)
      api.put(hash2, hdr2)
      var eh1, eh2: common.BlockHeader
      check api.get(hash1, eh1)
      check api.get(hash2, eh2)
      check eh1.gasLimit == hdr1.gasLimit
      check eh2.gasLimit == hdr2.gasLimit

proc mergeMain*() =
  # temporary disable it until engine API more stable
  testEngineAPI()
  testEngineApiSupport()

when isMainModule:
  mergeMain()
