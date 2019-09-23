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
    # conflicts between native int and big int.
    # gasFee calculation in modexp precompiled
    # contracts
    "modexp.json",
    # perhaps a design flaw with create/create2 opcode.
    # a conflict between balance checker and
    # static call context checker
    "create2noCash.json",

    # bcStateTests
    "BLOCKHASH_Bounds.json",
    "SuicidesMixingCoinbase.json",
    "TransactionFromCoinbaseHittingBlockGasLimit1.json",
    "blockhashTests.json",
    "randomStatetest123.json",
    "randomStatetest136.json",
    "randomStatetest160.json",
    "randomStatetest170.json",
    "randomStatetest223.json",
    "randomStatetest229.json",
    "randomStatetest241.json",
    "randomStatetest324.json",
    "randomStatetest328.json",
    "randomStatetest375.json",
    "randomStatetest377.json",
    "randomStatetest38.json",
    "randomStatetest441.json",
    "randomStatetest46.json",
    "randomStatetest549.json",
    "randomStatetest594.json",
    "randomStatetest619.json",
    "randomStatetest94.json",
    "suicideCoinbase.json",
    "suicideCoinbaseState.json",

    # bcRandomBlockhashTest
    "randomStatetest113BC.json",
    "randomStatetest127BC.json",
    "randomStatetest141BC.json",
    "randomStatetest165BC.json",
    "randomStatetest168BC.json",
    "randomStatetest182BC.json",
    "randomStatetest193BC.json",
    "randomStatetest218BC.json",
    "randomStatetest239BC.json",
    "randomStatetest272BC.json",
    "randomStatetest284BC.json",
    "randomStatetest330BC.json",
    "randomStatetest35BC.json",
    "randomStatetest390BC.json",
    "randomStatetest400BC.json",
    "randomStatetest40BC.json",
    "randomStatetest44BC.json",
    "randomStatetest459BC.json",
    "randomStatetest540BC.json",
    "randomStatetest613BC.json",
    "randomStatetest622BC.json",
    "randomStatetest623BC.json",
    "randomStatetest76BC.json",
    "randomStatetest79BC.json",

    # bcFrontierToHomestead
    "HomesteadOverrideFrontier.json",
    "blockChainFrontierWithLargerTDvsHomesteadBlockchain.json",
    "blockChainFrontierWithLargerTDvsHomesteadBlockchain2.json",

    # bcInvalidHeaderTest
    #"DifficultyIsZero.json",
    #"wrongDifficulty.json",
  ]
  result = name in allowedFailingGeneralStateTests
