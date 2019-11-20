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

import strutils

func slowGSTTests(folder: string, name: string): bool =
  result = folder == "stQuadraticComplexityTest" or
    name in @["randomStatetest352.json", "randomStatetest1.json",
             "randomStatetest32.json", "randomStatetest347.json",
             "randomStatetest393.json", "randomStatetest626.json",
             "CALLCODE_Bounds.json", "DELEGATECALL_Bounds3.json",
             "CALLCODE_Bounds4.json", "CALL_Bounds.json",
             "DELEGATECALL_Bounds2.json", "CALL_Bounds3.json",
             "CALLCODE_Bounds2.json", "CALLCODE_Bounds3.json",
             "DELEGATECALL_Bounds.json", "CALL_Bounds2a.json",
             "CALL_Bounds2.json",
             "CallToNameRegistratorMemOOGAndInsufficientBalance.json",
             "CallToNameRegistratorTooMuchMemory0.json",

              # all these tests below actually pass
              # but they are very slow

              # constantinople slow tests
              "Create2Recursive.json",

              # byzantium slow tests
              "LoopCallsDepthThenRevert3.json",
              "LoopCallsDepthThenRevert2.json",
              "LoopCallsDepthThenRevert.json",
              "static_Call50000.json",
              "static_Call50000_ecrec.json",
              "static_Call50000_identity.json",
              "static_Call50000_identity2.json",
              "static_Call50000_rip160.json",
              "static_Call50000_sha256.json",
              "LoopCallsThenRevert.json",
              "LoopDelegateCallsDepthThenRevert.json",
              "recursiveCreateReturnValue.json",
              "static_Call1024PreCalls2.json",
              "Callcode1024BalanceTooLow.json",
              "static_Call1024BalanceTooLow.json",
              "static_Call1024BalanceTooLow2.json",
              "static_Call1024OOG.json",
              "static_Call1024PreCalls3.json",
              "static_Call1024PreCalls.json",
              "static_Call1MB1024Calldepth.json",

              # Homestead recursives
              "ContractCreationSpam.json",
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
              "callcallcallcode_ABCB_RECURSIVE.json"
              ]

func failIn32Bits(folder, name: string): bool =
  return name in @[
    # crash with OOM
    "static_Return50000_2.json",
    "randomStatetest185.json",
    "randomStatetest159.json",
    "randomStatetest48.json",

    # OOM in AppVeyor, not on my machine
    "randomStatetest36.json"
  ]

func allowedFailingGeneralStateTest(folder, name: string): bool =
  let allowedFailingGeneralStateTests = @[
    # conflicts between native int and big int.
    # gasFee calculation in modexp precompiled
    # contracts
    "modexp.json",
    # perhaps a design flaw with create/create2 opcode.
    # a conflict between balance checker and
    # static call context checker
    "create2noCash.json"
  ]
  result = name in allowedFailingGeneralStateTests

func allowedFailInCurrentBuild(folder, name: string): bool =
  when sizeof(int) == 4:
    if failIn32Bits(folder, name):
      return true
  return allowedFailingGeneralStateTest(folder, name)

func skipGSTTests*(folder: string, name: string): bool =
  # we skip tests that are slow or expected to fail for now
  if slowGSTTests(folder, name):
    return true
  result = allowedFailInCurrentBuild(folder, name)

func skipNewGSTTests*(folder: string, name: string): bool =
  # share the same slow and failing tests
  if skipGSTTests(folder, name):
    return true

  result = name in @[
    # skip slow tests
    "CALLBlake2f_MaxRounds.json",

    # py-evm claims these tests are incorrect
    # nimbus also agree
    "RevertInCreateInInit.json",
    "RevertInCreateInInitCreate2.json",
    "InitCollision.json"
  ]

func skipVMTests*(folder: string, name: string): bool =
  when sizeof(int) == 4:
    if name == "sha3_bigSize.json":
      return true
  result = (folder == "vmPerformance" and "loop" in name)

func skipBCTests*(folder: string, name: string): bool =
  let allowedFailingBCTests = @[
    # BlockChain slow tests
    "SuicideIssue.json",

    # Failed tests
    "SuicidesMixingCoinbase.json",
  ]

  result =  name in allowedFailingBCTests

func skipNewBCTests*(folder: string, name: string): bool =
  let allowedFailingBCTests = @[
    # Istanbul bc tests
    # py-evm claims these tests are incorrect
    # nimbus also agree
    "RevertInCreateInInit.json",
    "RevertInCreateInInitCreate2.json",
    "InitCollision.json"
  ]

  result = name in allowedFailingBCTests

func skipTxTests*(folder: string, name: string): bool =
  # from test_transaction_json
  when sizeof(int) == 4:
    result = name == "RLPHeaderSizeOverflowInt32.json"
  else:
    false
