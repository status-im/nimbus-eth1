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
  std/[strutils, typetraits],
  chronicles,
  ./engine_spec

type
  PayloadAttributesFieldChange* = enum
    PayloadAttributesIncreaseTimestamp         = "Increase timestamp"
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

func plusOne[T:Bytes32|Hash32|Address](x: T): T =
  var z = x.data
  z[0] = z[0] + 1.byte
  T(z)

#func plusOne(x: Hash32): Hash32 =
#  var z = x.data
#  z[0] = z[0] + 1.byte
#  Hash32(z)
#
#func plusOne(x: Address): Address =
#  var z = distinctBase x
#  z[0] = z[0] + 1.byte
#  Address(z)

# Check that the payload id returned on a forkchoiceUpdated call is different
# when the attributes change
method execute(cs: UniquePayloadIDTest, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    onPayloadAttributesGenerated: proc(): bool =
      var attr = env.clMock.latestPayloadAttributes
      case cs.fieldModification
      of PayloadAttributesIncreaseTimestamp:
        attr.timestamp = w3Qty(attr.timestamp, 1)
      of PayloadAttributesRandom:
        attr.prevRandao = attr.prevRandao.plusOne
      of PayloadAttributesSuggestedFeeRecipient:
        attr.suggestedFeeRecipient = attr.suggestedFeeRecipient.plusOne
      of PayloadAttributesAddWithdrawal:
        let newWithdrawal = WithdrawalV1()
        var wd = attr.withdrawals.get
        wd.add newWithdrawal
        attr.withdrawals = Opt.some(wd)
      of PayloadAttributesRemoveWithdrawal:
        var wd = attr.withdrawals.get
        wd.delete(0)
        attr.withdrawals = Opt.some(wd)
      of PayloadAttributesModifyWithdrawalAmount,
        PayloadAttributesModifyWithdrawalIndex,
        PayloadAttributesModifyWithdrawalValidator,
        PayloadAttributesModifyWithdrawalAddress:
        testCond attr.withdrawals.isSome:
          fatal "Cannot modify withdrawal when there are no withdrawals"
        var wds = attr.withdrawals.get
        testCond wds.len > 0:
          fatal "Cannot modify withdrawal when there are no withdrawals"

        var wd = wds[0]
        case cs.fieldModification
        of PayloadAttributesModifyWithdrawalAmount:
          wd.amount = w3Qty(wd.amount, 1)
        of PayloadAttributesModifyWithdrawalIndex:
          wd.index = w3Qty(wd.index, 1)
        of PayloadAttributesModifyWithdrawalValidator:
          wd.validatorIndex = w3Qty(wd.validatorIndex, 1)
        of PayloadAttributesModifyWithdrawalAddress:
          wd.address = wd.address.plusOne
        else:
          fatal "Unknown field change", field=cs.fieldModification
          return false

        wds[0] = wd
        attr.withdrawals = Opt.some(wds)
      of PayloadAttributesParentBeaconRoot:
        testCond attr.parentBeaconBlockRoot.isSome:
          fatal "Cannot modify parent beacon root when there is no parent beacon root"
        let newBeaconRoot = attr.parentBeaconBlockRoot.get.plusOne
        attr.parentBeaconBlockRoot = Opt.some(newBeaconRoot)

      # Request the payload with the modified attributes and add the payload ID to the list of known IDs
      let version = env.engine.version(env.clMock.latestHeader.timestamp)
      let r = env.engine.client.forkchoiceUpdated(version, env.clMock.latestForkchoice, Opt.some(attr))
      r.expectNoError()
      testCond env.clMock.addPayloadID(env.engine, r.get.payloadID.get)
      return true
  ))
  testCond pbRes
  return true
