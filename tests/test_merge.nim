# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, os, strutils, typetraits],
  unittest2,
  json_rpc/[rpcserver, rpcclient],
  web3/[engine_api_types],
  ../nimbus/sync/protocol,
  ../nimbus/rpc,
  ../nimbus/common,
  ../nimbus/config,
  ../nimbus/core/[sealer, tx_pool, chain],
  ../nimbus/rpc/merge/[mergetypes, merger],
  ./test_helpers

const
  baseDir = "tests" / "merge"
  paramsFile = baseDir / "params.json"
  stepsFile = baseDir / "steps.json"

type
  Step = ref object
    name: string
    meth: string
    params: JSonNode
    expect: JsonNode
    error : bool

  Steps = ref object
    list: seq[Step]

proc parseStep(s: Step, node: JsonNode) =
  for k, v in node:
    case k
    of "name": s.name = v.getStr()
    of "method": s.meth = v.getStr()
    of "params": s.params = v
    of "expect": s.expect = v
    of "error": s.error = true
    else:
      doAssert(false, "unknown key: " & k)

proc parseSteps(node: JsonNode): Steps =
  let ss = Steps(list: @[])
  for n in node:
    let s = Step()
    s.parseStep(n)
    ss.list.add s
  ss

proc forkChoiceUpdate(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  let arg = step.params[1]
  if arg.kind == JNull:
    step.params.elems.setLen(1)

  let res = waitFor client.call(step.meth, step.params)
  check toLowerAscii($res) == toLowerAscii($step.expect)

proc getPayload(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  try:
    let res = waitFor client.call(step.meth, step.params)
    check toLowerAscii($res) == toLowerAscii($step.expect)
  except:
    check step.error == true

proc newPayload(step: Step, client: RpcClient, testStatusIMPL: var TestStatus) =
  let res = waitFor client.call(step.meth, step.params)
  check toLowerAscii($res) == toLowerAscii($step.expect)

proc runTest(steps: Steps) =
  let
    conf = makeConfig(@["--custom-network:" & paramsFile])
    ctx  = newEthContext()
    ethNode = setupEthNode(conf, ctx, eth)
    com = CommonRef.new(
      newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chainRef = newChain(com)

  com.initializeEmptyDb()

  var
    rpcServer = newRpcSocketServer(["127.0.0.1:" & $conf.rpcPort])
    client = newRpcSocketClient()
    txPool = TxPoolRef.new(com, conf.engineSigner)
    sealingEngine = SealingEngineRef.new(
      chainRef, ctx, conf.engineSigner,
      txPool, EnginePostMerge
    )
    merger = MergerRef.new(com.db)

  setupEthRpc(ethNode, ctx, com, txPool, rpcServer)
  setupEngineAPI(sealingEngine, rpcServer, merger)

  sealingEngine.start()
  rpcServer.start()
  waitFor client.connect("127.0.0.1", conf.rpcPort)

  suite "Engine API tests":
    for i, step in steps.list:
      test $i & " " & step.name:
        case step.meth
        of "engine_forkchoiceUpdatedV1":
          forkChoiceUpdate(step, client, testStatusIMPL)
        of "engine_getPayloadV1":
          getPayload(step, client, testStatusIMPL)
        of "engine_newPayloadV1":
          newPayload(step, client, testStatusIMPL)
        else:
          doAssert(false, "unknown method: " & step.meth)

  waitFor client.close()
  waitFor sealingEngine.stop()
  rpcServer.stop()
  waitFor rpcServer.closeWait()

proc testEngineAPI() =
  let node = parseJSON(readFile(stepsFile))
  let steps = parseSteps(node)
  runTest(steps)

proc toId(x: int): PayloadId =
  var id: distinctBase PayloadId
  id[^1] = x.byte
  PayloadId(id)

proc `==`(a, b: Quantity): bool =
  uint64(a) == uint64(b)

proc testEngineApiSupport() =
  var api = EngineAPIRef.new(nil)
  let
    id1 = toId(1)
    id2 = toId(2)
    ep1 = ExecutionPayloadV1(gasLimit: Quantity 100)
    ep2 = ExecutionPayloadV1(gasLimit: Quantity 101)
    hdr1 = EthBlockHeader(gasLimit: 100)
    hdr2 = EthBlockHeader(gasLimit: 101)
    hash1 = hdr1.blockHash
    hash2 = hdr2.blockHash

  suite "Test engine api support":
    test "test payload queue":
      api.put(id1, ep1)
      api.put(id2, ep2)
      var eep1, eep2: ExecutionPayloadV1
      check api.get(id1, eep1)
      check api.get(id2, eep2)
      check eep1.gasLimit == ep1.gasLimit
      check eep2.gasLimit == ep2.gasLimit

    test "test header queue":
      api.put(hash1, hdr1)
      api.put(hash2, hdr2)
      var eh1, eh2: EthBlockHeader
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
