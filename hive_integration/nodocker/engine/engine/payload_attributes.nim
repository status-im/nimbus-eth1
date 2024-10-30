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
  ./engine_spec,
  ../cancun/customizer

type
  InvalidPayloadAttributesTest* = ref object of EngineSpec
    description*: string
    customizer* : PayloadAttributesCustomizer
    syncing*    : bool

method withMainFork(cs: InvalidPayloadAttributesTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InvalidPayloadAttributesTest): string =
  var desc = "Invalid PayloadAttributes: " & cs.description
  if cs.syncing:
    desc.add " (Syncing)"
  desc

method execute(cs: InvalidPayloadAttributesTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Send a forkchoiceUpdated with invalid PayloadAttributes
  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool {.gcsafe.} =
      # Try to apply the new payload with invalid attributes
      var fcu = env.clMock.latestForkchoice
      if cs.syncing:
        # Setting a random hash will put the client into `SYNCING`
        fcu.headblockHash = Hash32.randomBytes()
      else:
        fcu.headblockHash = env.clMock.latestPayloadBuilt.blockHash

      info "Sending EngineForkchoiceUpdated with invalid payload attributes",
        syncing=cs.syncing, description=cs.description

      # Get the payload attributes
      var originalAttr = env.clMock.latestPayloadAttributes
      originalAttr.timestamp = w3Qty(originalAttr.timestamp, 1)
      let attr = cs.customizer.getPayloadAttributes(originalAttr)

      # 0) Check headBlock is known and there is no missing data, if not respond with SYNCING
      # 1) Check headBlock is VALID, if not respond with INVALID
      # 2) Apply forkchoiceState
      # 3) Check payloadAttributes, if invalid respond with error: code: Invalid payload attributes
      # 4) Start payload build process and respond with VALID
      let version = env.engine.version(env.clMock.latestPayloadBuilt.timestamp)
      if cs.syncing:
        # If we are SYNCING, the outcome should be SYNCING regardless of the validity of the payload atttributes
        let r = env.engine.client.forkchoiceUpdated(version, fcu, Opt.some(attr))
        r.expectPayloadStatus(PayloadExecutionStatus.syncing)
        r.expectPayloadID(Opt.none(Bytes8))
      else:
        let r = env.engine.client.forkchoiceUpdated(version, fcu, Opt.some(attr))
        r.expectErrorCode(engineApiInvalidPayloadAttributes)

        # Check that the forkchoice was applied, regardless of the error
        let s = env.engine.client.latestHeader()
        #s.ExpectationDescription = "Forkchoice is applied even on invalid payload attributes"
        s.expectHash(fcu.headblockHash)

      return true
    ))

  testCond pbRes
  return true
