import
  std/[options, times],
  ./test_env,
  ./types,
  chronicles,
  ../../tools/common/helpers,
  ../../nimbus/common/hardforks

type
  ECSpec* = ref object of BaseSpec
    exec*: proc(env: TestEnv): bool
    conf*: ChainConfig

const
  ShanghaiCapabilities = [
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
  ]
  CancunCapabilities = [
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_getPayloadV3",
  ]

proc ecImpl(env: TestEnv, minExpectedCaps: openArray[string]): bool =
  let res = env.client.exchangeCapabilities(@minExpectedCaps)
  testCond res.isOk:
    error "Unable request capabilities", msg=res.error

  let returnedCaps = res.get
  for x in minExpectedCaps:
    testCond x in returnedCaps:
      error "Expected capability not found", cap=x
  return true

proc ecShanghai(env: TestEnv): bool =
  ecImpl(env, ShanghaiCapabilities)

proc ecCancun(env: TestEnv): bool =
  ecImpl(env, CancunCapabilities)

proc getCCShanghai(timestamp: int): ChainConfig =
  result = getChainConfig("Shanghai")
  result.shanghaiTime = some(fromUnix(timestamp))

proc getCCCancun(timestamp: int): ChainConfig =
  result = getChainConfig("Cancun")
  result.cancunTime = some(fromUnix(timestamp))

proc specExecute(ws: BaseSpec): bool =
  let ws = ECSpec(ws)
  let env = TestEnv.new(ws.conf)
  result = ws.exec(env)
  env.close()

# const doesn't work with ref object
let ecTestList* = [
  TestDesc(
    name: "Exchange Capabilities - Shanghai",
    run: specExecute,
    spec: ECSpec(
      exec: ecShanghai,
      conf: getCCShanghai(0)
    )
  ),
  TestDesc(
    name: "Exchange Capabilities - Shanghai (Not active)",
    run: specExecute,
    spec: ECSpec(
      exec: ecShanghai,
      conf: getCCShanghai(1000)
    )
  ),
  TestDesc(
    name: "Exchange Capabilities - Cancun",
    run: specExecute,
    spec: ECSpec(
      exec: ecCancun,
      conf: getCCCancun(0)
    )
  ),
  TestDesc(
    name: "Exchange Capabilities - Cancun (Not active)",
    run: specExecute,
    spec: ECSpec(
      exec: ecCancun,
      conf: getCCCancun(1000)
    )
  )
]
