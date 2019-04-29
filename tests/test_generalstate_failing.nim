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
    # a family of UInt256 truncated to int problems
    "randomStatetest14.json", # SHA3 offset
    "randomStatetest85.json", # CALL* memoffset
    "sha3_deja.json", # SHA3 startPos
    # modexp exp_len & friends truncated to int
    # and not OOG where it should OOG
    "modexpRandomInput.json",

    "CreateOOGafterInitCodeReturndataSize.json",
    "RevertInCreateInInit.json",
    "modexp.json",

    # see precompiles getPoint[G2]
    "ecpairing_perturb_g2_by_field_modulus_again.json",
    "ecpairing_perturb_zeropoint_by_field_modulus.json",
    "ecpairing_perturb_g2_by_field_modulus.json",

    # 29/04/2019
    "RevertPrecompiledTouch.json",
    "RevertPrecompiledTouch_storage.json",

    # all these tests below actually pass
    # but they are very slow
    # byzantium slow
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
  result = name in allowedFailingGeneralStateTests
