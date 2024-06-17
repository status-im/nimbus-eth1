# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: System Operations
## ======================================
##

{.push raises: [].}

import
  ../../evm_errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stint

when not defined(evmc_enabled):
  import
    ../../state,
    ../../../db/ledger

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc returnOp(k: var VmCtx): EvmResultVoid =
  ## 0xf3, Halt execution returning output data.
  let (startPos, size) = ? k.cpt.stack.popInt(2)

  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
  ? k.cpt.opcodeGastCost(Return,
    k.cpt.gasCosts[Return].m_handler(k.cpt.memory.len, pos, len),
    reason = "RETURN")
  k.cpt.memory.extend(pos, len)
  k.cpt.output = k.cpt.memory.read(pos, len)
  ok()


proc revertOp(k: var VmCtx): EvmResultVoid =
  ## 0xfd, Halt execution reverting state changes but returning data
  ##       and remaining gas.
  let (startPos, size) = ? k.cpt.stack.popInt(2)

  let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
  ? k.cpt.opcodeGastCost(Revert,
    k.cpt.gasCosts[Revert].m_handler(k.cpt.memory.len, pos, len),
    reason = "REVERT")

  k.cpt.memory.extend(pos, len)
  k.cpt.output = k.cpt.memory.read(pos, len)
  # setError(msg, false) will signal cheap revert
  k.cpt.setError(EVMC_REVERT, "REVERT opcode executed", false)
  ok()

proc invalidOp(k: var VmCtx): EvmResultVoid =
  err(opErr(InvalidInstruction))

# -----------

proc selfDestructOp(k: var VmCtx): EvmResultVoid =
  ## 0xff, Halt execution and register account for later deletion.
  let cpt = k.cpt
  let beneficiary = ? cpt.stack.popAddress()
  when defined(evmc_enabled):
    block:
      cpt.selfDestruct(beneficiary)
  else:
    block:
      cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP150Op(k: var VmCtx): EvmResultVoid =
  ## selfDestructEip150 (auto generated comment)
  let cpt = k.cpt
  let beneficiary = ? cpt.stack.popAddress()
  block:
    let gasParams = GasParams(
      kind: SelfDestruct,
      sd_condition: not cpt.accountExists(beneficiary))

    let res = ? cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams)
    ? cpt.opcodeGastCost(SelfDestruct,
        res.gasCost, reason = "SELFDESTRUCT EIP150")
    cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP161Op(k: var VmCtx): EvmResultVoid =
  ## selfDestructEip161 (auto generated comment)
  let cpt = k.cpt
  ? checkInStaticContext(cpt)

  let beneficiary = ? cpt.stack.popAddress()
  block:
    let
      isDead = not cpt.accountExists(beneficiary)
      balance = cpt.getBalance(cpt.msg.contractAddress)

    let gasParams = GasParams(
      kind: SelfDestruct,
      sd_condition: isDead and not balance.isZero)

    let res = ? cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams)
    ? cpt.opcodeGastCost(SelfDestruct,
      res.gasCost, reason = "SELFDESTRUCT EIP161")
    cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP2929Op(k: var VmCtx): EvmResultVoid =
  ## selfDestructEIP2929 (auto generated comment)
  let cpt = k.cpt
  ? checkInStaticContext(cpt)

  let beneficiary = ? cpt.stack.popAddress()
  block:
    let
      isDead = not cpt.accountExists(beneficiary)
      balance = cpt.getBalance(cpt.msg.contractAddress)

    let
      gasParams = GasParams(
        kind: SelfDestruct,
        sd_condition: isDead and not balance.isZero)
      res = ? cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams)

    var gasCost = res.gasCost

    when evmc_enabled:
      if cpt.host.accessAccount(beneficiary) == EVMC_ACCESS_COLD:
        gasCost = gasCost + ColdAccountAccessCost
    else:
      cpt.vmState.mutateStateDB:
        if not db.inAccessList(beneficiary):
          db.accessList(beneficiary)
          gasCost = gasCost + ColdAccountAccessCost

    ? cpt.opcodeGastCost(SelfDestruct,
      gasCost, reason = "SELFDESTRUCT EIP2929")
    cpt.selfDestruct(beneficiary)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecSysOp*: seq[VmOpExec] = @[

    (opCode: Return,       ## 0xf3, Halt execution returning output data.
     forks: VmOpAllForks,
     name: "returnOp",
     info: "Halt execution returning output data",
     exec: (prep: VmOpIgnore,
            run: returnOp,
            post: VmOpIgnore)),

    (opCode: Revert,       ## 0xfd, Halt and revert state changes
     forks: VmOpByzantiumAndLater,
     name: "revert",
     info: "Halt execution reverting state changes but returning data " &
           "and remaining gas",
     exec: (prep: VmOpIgnore,
            run: revertOp,
            post: VmOpIgnore)),

    (opCode: Invalid,      ## 0xfe, invalid instruction.
     forks: VmOpAllForks,
     name: "invalidInstruction",
     info: "Designated invalid instruction",
     exec: (prep: VmOpIgnore,
            run: invalidOp,
            post: VmOpIgnore)),

    (opCode: SelfDestruct, ## 0xff, Halt execution, prep for later deletion
     forks: VmOpAllForks - VmOpTangerineAndLater,
     name: "selfDestruct",
     info: "Halt execution and register account for later deletion",
     exec: (prep: VmOpIgnore,
            run:  selfDestructOp,
            post: VmOpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP150: self destruct, Tangerine
     forks: VmOpTangerineAndLater - VmOpSpuriousAndLater,
     name: "selfDestructEIP150",
     info: "EIP150: Halt execution and register account for later deletion",
     exec: (prep: VmOpIgnore,
            run:  selfDestructEIP150Op,
            post: VmOpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP161: self destruct, Spurious and later
     forks: VmOpSpuriousAndLater - VmOpBerlinAndLater,
     name: "selfDestructEIP161",
     info: "EIP161: Halt execution and register account for later deletion",
     exec: (prep: VmOpIgnore,
            run:  selfDestructEIP161Op,
            post: VmOpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP2929: self destruct, Berlin and later
     forks: VmOpBerlinAndLater,
     name: "selfDestructEIP2929",
     info: "EIP2929: Halt execution and register account for later deletion",
     exec: (prep: VmOpIgnore,
            run:  selfDestructEIP2929Op,
            post: VmOpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
