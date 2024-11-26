# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  chronicles,
  ./step_desc,
  ./customizer,
  ../test_env,
  ../types

# Send a modified version of the latest payload produced using NewPayloadV3
type
  SendModifiedLatestPayload* = ref object of TestStep
    clientID*            : int
    newPayloadCustomizer*: NewPayloadCustomizer

method execute*(step: SendModifiedLatestPayload, ctx: CancunTestContext): bool =
  # Get the latest payload
  doAssert(step.newPayloadCustomizer.isNil.not, "TEST-FAIL: no payload customizer available")

  var
    env = ctx.env
    payload        = env.clMock.latestExecutableData
    expectedError  = step.newPayloadCustomizer.getExpectedError()
    expectedStatus = PayloadExecutionStatus.valid

  doAssert(env.clMock.latestBlobsBundle.isSome, "TEST-FAIL: no blob bundle available")

  # Send a custom new payload
  step.newPayloadCustomizer.setEngineAPIVersionResolver(env.engine.com)

  payload = step.newPayloadCustomizer.customizePayload(payload)
  let version = step.newPayloadCustomizer.newPayloadVersion(payload.timestamp.uint64)

  if step.newPayloadCustomizer.getExpectInvalidStatus():
    expectedStatus = PayloadExecutionStatus.invalid

  # Send the payload
  doAssert(step.clientID < env.numEngines(), "invalid client index " & $step.clientID)

  let eng = env.engines(step.clientID)
  let r = eng.newPayload(version, payload)
  if expectedError != 0:
    r.expectErrorCode(expectedError)
  else:
    r.expectStatus(expectedStatus)

  return true

method description*(step: SendModifiedLatestPayload): string =
  let desc = "SendModifiedLatestPayload: client $1, expected invalid=$2" % [
    $step.clientID, $step.newPayloadCustomizer.getExpectInvalidStatus()]
  #[
    TODO: Figure out if we need this.
    if step.VersionedHashes != nil {
      desc += step.VersionedHashes.Description()
    }
  ]#
  return desc
