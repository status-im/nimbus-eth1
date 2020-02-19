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
              "callcallcallcode_ABCB_RECURSIVE.json",

              # Istanbul slow tests
              "CALLBlake2f_MaxRounds.json",
              ]

func skipGSTTests*(folder: string, name: string): bool =
  # we skip tests that are slow or expected to fail for now
  slowGSTTests(folder, name)

func skipNewGSTTests*(folder: string, name: string): bool =
  # share the same slow and failing tests
  if skipGSTTests(folder, name):
    return true

func skipVMTests*(folder: string, name: string): bool =
  result = (folder == "vmPerformance" and "loop" in name)

func skipBCTests*(folder: string, name: string): bool =
  name in @[
    # BlockChain slow tests
    "SuicideIssue.json",

    # BC huge memory consumption
    "randomStatetest94.json",
    "DelegateCallSpam.json"
  ]

func skipNewBCTests*(folder: string, name: string): bool =
  # the new BC tests also contains these slow tests
  # for Istanbul fork
  if slowGSTTests(folder, name):
    return true

  name in @[
    # BC huge memory consumption
    "randomStatetest94.json",
    "DelegateCallSpam.json"
  ]
