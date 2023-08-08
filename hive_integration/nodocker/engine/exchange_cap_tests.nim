import
  ./test_env,
  ./types,
  unittest2,
  chronicles,
  ../../tools/common/helpers,
  ../../nimbus/common/hardforks

type
  ECTestSpec* = object
    name*: string
    run*: proc(t: TestEnv): TestStatus
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

proc ecImpl(t: TestEnv, minExpectedCaps: openArray[string]): TestStatus =
  result = TestStatus.OK
  let res = t.rpcClient.exchangeCapabilities(@minExpectedCaps)
  testCond res.isOk:
    error "Unable request capabilities", msg=res.error

  let returnedCaps = res.get
  for x in minExpectedCaps:
    testCond x in returnedCaps:
      error "Expected capability not found", cap=x

proc ecShanghai(env: TestEnv): TestStatus =
  ecImpl(env, ShanghaiCapabilities)

proc ecCancun(env: TestEnv): TestStatus =
  ecImpl(env, CancunCapabilities)

proc getCCShanghai(timestamp: int): ChainConfig =
  result = getChainConfig("Shanghai")
  result.shanghaiTime = some(fromUnix(timestamp))

proc getCCCancun(timestamp: int): ChainConfig =
  result = getChainConfig("Cancun")
  result.cancunTime = some(fromUnix(timestamp))

# const doesn't work with ref object
let exchangeCapTestList* = [
  ECTestSpec(
    name: "Exchange Capabilities - Shanghai",
    run: ecShanghai,
    conf: getCCShanghai(0)
  ),
  ECTestSpec(
    name: "Exchange Capabilities - Shanghai (Not active)",
    run: ecShanghai,
    conf: getCCShanghai(1000)
  ),
  ECTestSpec(
    name: "Exchange Capabilities - Cancun",
    run: ecCancun,
    conf: getCCCancun(0)
  ),
  ECTestSpec(
    name: "Exchange Capabilities - Cancun (Not active)",
    run: ecCancun,
    conf: getCCCancun(1000)
  )
]
