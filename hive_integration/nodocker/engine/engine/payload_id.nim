# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  ./engine_spec

type
  PayloadAttributesFieldChange* = enum
    PayloadAttributesIncreasetimestamp         = "Increase timestamp"
    PayloadAttributesRandom                    = "Modify Random"
    PayloadAttributesSuggestedFeeRecipient     = "Modify SuggestedFeeRecipient"
    PayloadAttributesAddWithdrawal             = "Add Withdrawal"
    PayloadAttributesModifyWithdrawalAmount    = "Modify Withdrawal Amount"
    PayloadAttributesModifyWithdrawalIndex     = "Modify Withdrawal Index"
    PayloadAttributesModifyWithdrawalValidator = "Modify Withdrawal Validator"
    PayloadAttributesModifyWithdrawalAddress   = "Modify Withdrawal Address"
    PayloadAttributesRemoveWithdrawal          = "Remove Withdrawal"
    PayloadAttributesParentBeaconRoot          = "Modify Parent Beacon Root"

  UniquePayloadIDTest* = ref object of EngineSpec
    fieldModification*: PayloadAttributesFieldChange

method withMainFork(cs: UniquePayloadIDTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: UniquePayloadIDTest): string =
  "Unique Payload ID - " & $cs.fieldModification

# Check that the payload id returned on a forkchoiceUpdated call is different
# when the attributes change
method execute(cs: UniquePayloadIDTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadAttributesGenerated: proc(): bool =
      payloadAttributes = env.clMock.latestPayloadAttributes
      case cs.fieldModification (
      of PayloadAttributesIncreasetimestamp:
        payloadAttributes.timestamp += 1
      of PayloadAttributesRandom:
        payloadAttributes.Random[0] = payloadAttributes.Random[0] + 1
      of PayloadAttributesSuggestedFeerecipient:
        payloadAttributes.SuggestedFeeRecipient[0] = payloadAttributes.SuggestedFeeRecipient[0] + 1
      of PayloadAttributesAddWithdrawal:
        newWithdrawal = &types.Withdrawal()
        payloadAttributes.Withdrawals = append(payloadAttributes.Withdrawals, newWithdrawal)
      of PayloadAttributesRemoveWithdrawal:
        payloadAttributes.Withdrawals = payloadAttributes.Withdrawals[1:]
      of PayloadAttributesModifyWithdrawalAmount,
        PayloadAttributesModifyWithdrawalIndex,
        PayloadAttributesModifyWithdrawalValidator,
        PayloadAttributesModifyWithdrawalAddress:
        if len(payloadAttributes.Withdrawals) == 0 (
          fatal "Cannot modify withdrawal when there are no withdrawals")
        )
        modifiedWithdrawal = *payloadAttributes.Withdrawals[0]
        case cs.fieldModification (
        of PayloadAttributesModifyWithdrawalAmount:
          modifiedWithdrawal.Amount += 1
        of PayloadAttributesModifyWithdrawalIndex:
          modifiedWithdrawal.Index += 1
        of PayloadAttributesModifyWithdrawalValidator:
          modifiedWithdrawal.Validator += 1
        of PayloadAttributesModifyWithdrawalAddress:
          modifiedWithdrawal.Address[0] = modifiedWithdrawal.Address[0] + 1
        )
        payloadAttributes.Withdrawals = append(types.Withdrawals(&modifiedWithdrawal), payloadAttributes.Withdrawals[1:]...)
      of PayloadAttributesParentBeaconRoot:
        if payloadAttributes.BeaconRoot == nil (
          fatal "Cannot modify parent beacon root when there is no parent beacon root")
        )
        newBeaconRoot = *payloadAttributes.BeaconRoot
        newBeaconRoot[0] = newBeaconRoot[0] + 1
        payloadAttributes.BeaconRoot = &newBeaconRoot
      default:
        fatal "Unknown field change: %s", cs.fieldModification)
      )

      # Request the payload with the modified attributes and add the payload ID to the list of known IDs
      let version = env.engine.version(env.clMock.latestHeader.timestamp)
      let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice, some(payloadAttributes))
      r.expectNoError()
      env.clMock.addPayloadID(env.engine, r.get.payloadID.get)
    ),
  ))
)
