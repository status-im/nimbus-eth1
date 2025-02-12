# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ../cancun/customizer,
  ../../../../execution_chain/utils/utils

type
  ForkchoiceStateField* = enum
    HeadBlockHash      = "Head"
    SafeBlockHash      = "Safe"
    FinalizedBlockHash = "Finalized"

type
  InconsistentForkchoiceTest* = ref object of EngineSpec
    field*: ForkchoiceStateField

  Shadow = ref object
    canon: seq[ExecutableData]
    alt: seq[ExecutableData]

method withMainFork(cs: InconsistentForkchoiceTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InconsistentForkchoiceTest): string =
  return "Inconsistent $1 in ForkchoiceState" % [$cs.field]

# Send an inconsistent ForkchoiceState with a known payload that belongs to a side chain as head, safe or finalized.
method execute(cs: InconsistentForkchoiceTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  var shadow = Shadow()

  # Produce blocks before starting the test
  let pbRes = env.clMock.produceBlocks(3, BlockProcessCallbacks(
    onGetPayload: proc(): bool =
      # Generate and send an alternative side chain
      var customData = CustomPayloadData(
        extraData: Opt.some(@[0x01.byte])
      )

      if shadow.alt.len > 0:
        customData.parentHash = Opt.some(shadow.alt[^1].blockHash)

      let altPayload = customData.customizePayload(env.clMock.latestExecutableData)
      shadow.alt.add altPayload
      shadow.canon.add env.clMock.latestExecutableData

      # Send the alternative payload
      let r = env.engine.newPayload(altPayload)
      r.expectStatusEither([PayloadExecutionStatus.valid, PayloadExecutionStatus.accepted])
      return true
  ))

  testCond pbRes

  # Send the invalid ForkchoiceStates
  var inconsistentFcU = ForkchoiceStateV1(
    headblockHash:      shadow.canon[len(shadow.alt)-1].blockHash,
    safeblockHash:      shadow.canon[len(shadow.alt)-2].blockHash,
    finalizedblockHash: shadow.canon[len(shadow.alt)-3].blockHash,
  )

  case cs.field
  of HeadBlockHash:
    inconsistentFcU.headBlockHash = shadow.alt[len(shadow.alt)-1].blockHash
  of SafeBlockHash:
    inconsistentFcU.safeBlockHash = shadow.alt[len(shadow.canon)-2].blockHash
  of FinalizedBlockHash:
    inconsistentFcU.finalizedBlockHash = shadow.alt[len(shadow.canon)-3].blockHash

  let timeVer = env.clMock.latestPayloadBuilt.timestamp
  var r = env.engine.forkchoiceUpdated(timeVer, inconsistentFcU)
  r.expectErrorCode(engineApiInvalidForkchoiceState)

  # Return to the canonical chain
  r = env.engine.forkchoiceUpdated(timeVer, env.clMock.latestForkchoice)
  r.expectPayloadStatus(PayloadExecutionStatus.valid)
  return true

type
  ForkchoiceUpdatedUnknownBlockHashTest* = ref object of EngineSpec
    field*: ForkchoiceStateField

method withMainFork(cs: ForkchoiceUpdatedUnknownBlockHashTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ForkchoiceUpdatedUnknownBlockHashTest): string =
  return "Unknown $1blockHash" % [$cs.field]

# Send an inconsistent ForkchoiceState with a known payload that belongs to a side chain as head, safe or finalized.
method execute(cs: ForkchoiceUpdatedUnknownBlockHashTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  # Generate a random block hash
  let randomblockHash = Hash32.randomBytes()

  if cs.field == HeadBlockHash:
    let fcu = ForkchoiceStateV1(
      headBlockHash:      randomblockHash,
      safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
      finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
    )

    info "forkchoiceStateUnknownHeadHash",
      head=fcu.headBlockHash.short,
      safe=fcu.safeBlockHash.short,
      final=fcu.finalizedBlockHash.short

    # Execution specification::
    # - (payloadStatus: (status: SYNCING, latestValidHash: null, validationError: null), payloadId: null)
    #   if forkchoiceState.headblockHash references an unknown payload or a payload that can't be validated
    #   because requisite data for the validation is missing
    let timeVer = env.clMock.latestExecutedPayload.timestamp
    var r = env.engine.forkchoiceUpdated(timeVer, fcu)
    r.expectPayloadStatus(PayloadExecutionStatus.syncing)

    var payloadAttributes = env.clMock.latestPayloadAttributes
    payloadAttributes.timestamp = w3Qty(payloadAttributes.timestamp, 1)

    # Test again using PayloadAttributes, should also return SYNCING and no PayloadID
    r = env.engine.forkchoiceUpdated(timeVer, fcu, Opt.some(payloadAttributes))
    r.expectPayloadStatus(PayloadExecutionStatus.syncing)
    r.expectPayloadID(Opt.none(Bytes8))
  else:
    let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
      # Run test after a new payload has been broadcast
      onNewPayloadBroadcast: proc(): bool =
        var fcu = ForkchoiceStateV1(
          headBlockHash:      env.clMock.latestExecutedPayload.blockHash,
          safeBlockHash:      env.clMock.latestForkchoice.safeBlockHash,
          finalizedBlockHash: env.clMock.latestForkchoice.finalizedBlockHash,
        )

        if cs.field == SafeBlockHash:
          fcu.safeBlockHash = randomblockHash
        elif cs.field == FinalizedBlockHash:
          fcu.finalizedBlockHash = randomblockHash

        let timeVer = env.clMock.latestExecutedPayload.timestamp
        var r = env.engine.forkchoiceUpdated(timeVer, fcu)
        r.expectError()

        var payloadAttributes = env.clMock.latestPayloadAttributes
        payloadAttributes.prevRandao = default(Bytes32)
        payloadAttributes.suggestedFeeRecipient = default(Address)

        # Test again using PayloadAttributes, should also return INVALID and no PayloadID
        r = env.engine.forkchoiceUpdated(timeVer, fcu, Opt.some(payloadAttributes))
        r.expectError()
        return true
    ))
    testCond pbRes

  return true
