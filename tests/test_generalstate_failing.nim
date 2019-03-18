# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# XXX: when all but a relative few dozen, say, GeneralStateTests run, remove this,
# but for now, this enables some CI use before that to prevent regressions. In the
# separate file here because it would otherwise just distract. Could use all sorts
# of O(1) or O(log n) lookup structures, or be more careful to only initialize the
# table once, but notion's that it should shrink reasonable quickly and disappear,
# being mostly used for short-term regression prevention.
func allowedFailingGeneralStateTest*(folder, name: string): bool =
  let allowedFailingGeneralStateTests = @[
    "TransactionCollisionToEmptyButCode.json",
    "TransactionCollisionToEmptyButNonce.json",
    "deleagateCallAfterValueTransfer.json",
    "delegatecallInInitcodeToEmptyContract.json",
    "delegatecallInInitcodeToExistingContract.json",
    "delegatecallSenderCheck.json",
    "delegatecallValueCheck.json",
    "delegatecodeDynamicCode.json",
    "delegatecodeDynamicCode2SelfCall.json",
    "CALLCODEEcrecoverV_prefixedf0.json",
    "randomStatetest14.json",
    "randomStatetest184.json",
    "randomStatetest85.json",
    "RevertOpcodeCalls.json",
    "RevertOpcodeDirectCall.json",
    "RevertOpcodeInCallsOnNonEmptyReturnData.json",
    "RevertOpcodeMultipleSubCalls.json",
    "RevertOpcodeReturn.json",
    "tx_e1c174e2.json",
    "suicideCoinbase.json",
    "Opcodes_TransactionInit.json",
    "SuicidesMixingCoinbase.json",
    "TransactionFromCoinbaseHittingBlockGasLimit1.json",
    "delegatecallAfterTransition.json",
    "delegatecallAtTransition.json",
    "delegatecallBeforeTransition.json",
    # 2018-12-07:
    # 2019-02-07:
    # 2019-02-15:
    "randomStatetest101.json",
    "randomStatetest7.json",
    # 2019-02-17:
    "pairingTest.json",
    "pointAdd.json",
    "pointAddTrunc.json",
    "pointMulAdd.json",
    "pointMulAdd2.json",
    # most likely to crash:
    "ContractCreationSpam.json",
    "Call1024OOG.json",
    "Call1024PreCalls.json",
    "CallRecursiveBombPreCall.json",
    "Delegatecall1024.json",
    "Delegatecall1024OOG.json",
    "recursiveCreate.json",
    "recursiveCreateReturnValue.json",
    "JUMPDEST_Attack.json",
    "JUMPDEST_AttackwithJump.json",
    "ABAcalls1.json",
    "ABAcalls2.json",
    "CallRecursiveBomb0.json",
    "CallRecursiveBomb0_OOG_atMaxCallDepth.json",
    "CallRecursiveBomb1.json",
    "CallRecursiveBomb2.json",
    "CallRecursiveBombLog.json",
    "CallRecursiveBombLog2.json",
    "Call1024BalanceTooLow.json",
    # Frontier recursive
    "Callcode1024OOG.json",
    "callcallcodecall_ABCB_RECURSIVE.json",
    "callcallcodecallcode_ABCB_RECURSIVE.json",
    "callcodecallcall_ABCB_RECURSIVE.json",
    "callcodecallcallcode_ABCB_RECURSIVE.json",
    "callcodecallcodecall_ABCB_RECURSIVE.json",
    "callcodecallcodecallcode_ABCB_RECURSIVE.json",
    # Frontier failed test cases    
    "callcallcallcode_001_OOGMAfter_1.json",
    "callcallcallcode_001_OOGMAfter_2.json",    
    "callcallcodecall_010_OOGMAfter.json",

    # Failed in homestead but OK in Frontier
    "callcallcallcode_001.json",
    "callcallcallcode_001_OOGE.json",
    "callcallcallcode_001_OOGMAfter.json",
    "callcallcallcode_001_OOGMBefore.json",
    "callcallcallcode_001_SuicideEnd.json",
    "callcallcallcode_ABCB_RECURSIVE.json",
    "callcallcode_01.json",
    "callcallcode_01_OOGE.json",
    "callcallcode_01_SuicideEnd.json",
    "callcallcodecall_010.json",
    "callcallcodecall_010_OOGMBefore.json",
    "callcallcodecall_010_SuicideEnd.json",
    "callcallcodecall_010_SuicideMiddle.json",
    "callcallcodecallcode_011.json",
    "callcallcodecallcode_011_OOGMAfter.json",
    "callcallcodecallcode_011_SuicideEnd.json",
    "callcallcodecallcode_011_SuicideMiddle.json",
    "callcallcallcode_001.json",
    "callcallcallcode_001_OOGMAfter.json",
    "callcallcode_01.json",
    "callcallcodecall_010.json",
    "callcallcodecallcode_011.json",
    "callcodecallcall_100.json",
    "callcodecallcallcode_101.json",
    "callcodecallcode_11.json",
    "callcodecallcodecall_110.json",
    "callcodecallcodecallcode_111.json",
    "CallLoseGasOOG.json",
    "CallcodeLoseGasOOG.json",
    "callOutput1.json",
    "callOutput2.json",
    "callOutput3.json",
    "callOutput3Fail.json",
    "callOutput3partial.json",
    "callOutput3partialFail.json",
    "callcodeOutput1.json",
    "callcodeOutput2.json",
    "callcodeOutput3.json",
    "callcodeOutput3Fail.json",
    "callcodeOutput3partial.json",
    "callcodeOutput3partialFail.json"
  ]
  result = name in allowedFailingGeneralStateTests
