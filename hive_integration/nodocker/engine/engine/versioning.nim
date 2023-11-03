# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Test versioning of the Engine API methods
import
  std/strutils,
  chronicles,
  ../cancun/customizer,
  ./engine_spec

type
  EngineNewPayloadVersionTest* = ref object of EngineSpec

method withMainFork(cs: EngineNewPayloadVersionTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

# Test modifying the ForkchoiceUpdated version on Payload Request to the previous/upcoming version
# when the timestamp payload attribute does not match the upgraded/downgraded version.
type
  ForkchoiceUpdatedOnPayloadRequestTest* = ref object of EngineSpec
    name*: string
    about*: string
    forkchoiceUpdatedCustomizer*: ForkchoiceUpdatedCustomizer
    payloadAttributesCustomizer*: PayloadAttributesCustomizer

method withMainFork(cs: ForkchoiceUpdatedOnPayloadRequestTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ForkchoiceUpdatedOnPayloadRequestTest): string =
  "ForkchoiceUpdated Version on Payload Request: " & cs.name

method execute(cs: ForkchoiceUpdatedOnPayloadRequestTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  let pbRes = env.clMock.produceSingleBlock(clmock.BlockProcessCallbacks(
    onPayloadAttributesGenerated: proc(): bool =
      var
        attr = env.clMock.latestPayloadAttributes
        expectedStatus = PayloadExecutionStatus.valid

      attr = cs.payloadAttributesCustomizer.getPayloadAttributes(attr)

      let expectedError = cs.forkchoiceUpdatedCustomizer.getExpectedError()
      if cs.forkchoiceUpdatedCustomizer.getExpectInvalidStatus():
        expectedStatus = PayloadExecutionStatus.invalid

      cs.forkchoiceUpdatedCustomizer.setEngineAPIVersionResolver(env.engine.com)
      let version = cs.forkchoiceUpdatedCustomizer.forkchoiceUpdatedVersion(env.clMock.latestHeader.timestamp.uint64)
      let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice, some(attr))
      #r.ExpectationDescription = cs.Expectation
      if expectedError != 0:
        r.expectErrorCode(expectedError)
      else:
        r.expectNoError()
        r.expectPayloadStatus(expectedStatus)
      return true
  ))
  testCond pbRes
  return true
