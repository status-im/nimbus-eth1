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
    "randomStatetest14.json", # SHA3 offset
    "randomStatetest85.json", # CALL* memoffset

    # Tangerine failed GST
    "doubleSelfdestructTest.json",
    "doubleSelfdestructTest2.json",

    # Spurious Dragon failed GST
    "CallContractToCreateContractOOG.json",
    "failed_tx_xcf416c53.json",
    "TransactionSendingToZero.json"

    #"OutOfGasContractCreation.json",
    #"OutOfGasPrefundedContractCreation.json",
    #"RevertOpcodeInInit.json",
    #"RevertOpcodeWithBigOutputInInit.json",
    #"createNameRegistratorPerTxsNotEnoughGasAfter.json",
    #"createNameRegistratorPerTxsNotEnoughGasAt.json",
    #"createNameRegistratorPerTxsNotEnoughGasBefore.json",
    #"ZeroValue_CALLCODE_ToEmpty.json",
    #"ZeroValue_CALLCODE_ToOneStorageKey.json",
    #"NonZeroValue_CALLCODE_ToEmpty.json",
    #"NonZeroValue_CALLCODE_ToOneStorageKey.json",
    #"suicideCoinbase.json",
    #"EmptyTransaction2.json",
    #"SuicidesMixingCoinbase.json",
    #"UserTransactionZeroCost.json",
    #"UserTransactionZeroCostWithData.json",
    #"NotEnoughCashContractCreation.json",
    #"201503110226PYTHON_DUP6.json",
    #"CreateTransactionReverted.json",
    #"EmptyTransaction.json",
    #"OverflowGasRequire.json",
    #"RefundOverflow.json",
    #"RefundOverflow2.json",
    #"TransactionNonceCheck.json",
    #"TransactionNonceCheck2.json",
    #"TransactionToItselfNotEnoughFounds.json",
    #"UserTransactionGasLimitIsTooLowWhenZeroCost.json",

    # Homestead recursives
    #["ContractCreationSpam.json",
    "Call1024OOG.json",
    "Call1024PreCalls.json",
    "CallRecursiveBombPreCall.json",
    "Delegatecall1024.json",
    "Delegatecall1024OOG.json",
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
    # Frontier recursives
    "Callcode1024OOG.json",
    "callcallcodecall_ABCB_RECURSIVE.json",
    "callcallcodecallcode_ABCB_RECURSIVE.json",
    "callcodecallcall_ABCB_RECURSIVE.json",
    "callcodecallcallcode_ABCB_RECURSIVE.json",
    "callcodecallcodecall_ABCB_RECURSIVE.json",
    "callcodecallcodecallcode_ABCB_RECURSIVE.json",
    "callcallcallcode_ABCB_RECURSIVE.json",]#
  ]
  result = name in allowedFailingGeneralStateTests
