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
  stew/assign2,
  ../../evm_errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../op_codes,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stint

when not defined(evmc_enabled):
  import ../../state, ../../../db/ledger

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc returnOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf3, Halt execution returning output data.
  ?cpt.stack.lsCheck(2)
  let
    pos = cpt.stack.lsPeekMemRef(^1)
    len = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(2)

  ?cpt.opcodeGasCost(
    Return, cpt.gasCosts[Return].m_handler(cpt.memory.len, pos, len), reason = "RETURN"
  )

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))
  ok()

proc revertOp(cpt: VmCpt): EvmResultVoid =
  ## 0xfd, Halt execution reverting state changes but returning data
  ##       and remaining gas.
  ?cpt.stack.lsCheck(2)
  let
    pos = cpt.stack.lsPeekMemRef(^1)
    len = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(2)

  ?cpt.opcodeGasCost(
    Revert, cpt.gasCosts[Revert].m_handler(cpt.memory.len, pos, len), reason = "REVERT"
  )

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))
  # setError(msg, false) will signal cheap revert
  cpt.setError(EVMC_REVERT, "REVERT opcode executed", false)
  ok()

proc invalidOp(cpt: VmCpt): EvmResultVoid =
  err(opErr(InvalidInstruction))

# -----------

proc selfDestructOp(cpt: VmCpt): EvmResultVoid =
  ## 0xff, Halt execution and register account for later deletion.
  let beneficiary = ?cpt.stack.popAddress()

  when defined(evmc_enabled):
    cpt.selfDestruct(beneficiary)
  else:
    cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP150Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEip150 (auto generated comment)
  let
    beneficiary = ?cpt.stack.popAddress()
    condition = not cpt.accountExists(beneficiary)
    gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  ?cpt.opcodeGasCost(SelfDestruct, gasCost, reason = "SELFDESTRUCT EIP150")
  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP161Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEip161 (auto generated comment)
  ?cpt.checkInStaticContext()

  let
    beneficiary = ?cpt.stack.popAddress()
    isDead = not cpt.accountExists(beneficiary)
    balance = cpt.getBalance(cpt.msg.contractAddress)
    condition = isDead and not balance.isZero
    gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  ?cpt.opcodeGasCost(SelfDestruct, gasCost, reason = "SELFDESTRUCT EIP161")
  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEIP2929 (auto generated comment)
  ?cpt.checkInStaticContext()

  let
    beneficiary = ?cpt.stack.popAddress()
    isDead = not cpt.accountExists(beneficiary)
    balance = cpt.getBalance(cpt.msg.contractAddress)
    condition = isDead and not balance.isZero

  var gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  when evmc_enabled:
    if cpt.host.accessAccount(beneficiary) == EVMC_ACCESS_COLD:
      gasCost = gasCost + ColdAccountAccessCost
  else:
    cpt.vmState.mutateStateDB:
      if not db.inAccessList(beneficiary):
        db.accessList(beneficiary)
        gasCost = gasCost + ColdAccountAccessCost

  ?cpt.opcodeGasCost(SelfDestruct, gasCost, reason = "SELFDESTRUCT EIP2929")
  cpt.selfDestruct(beneficiary)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const VmOpExecSysOp*: seq[VmOpExec] =
  @[
    (
      opCode: Return, ## 0xf3, Halt execution returning output data.
      forks: VmOpAllForks,
      name: "returnOp",
      info: "Halt execution returning output data",
      exec: returnOp,
    ),
    (
      opCode: Revert, ## 0xfd, Halt and revert state changes
      forks: VmOpByzantiumAndLater,
      name: "revert",
      info:
        "Halt execution reverting state changes but returning data " &
        "and remaining gas",
      exec: revertOp,
    ),
    (
      opCode: Invalid, ## 0xfe, invalid instruction.
      forks: VmOpAllForks,
      name: "invalidInstruction",
      info: "Designated invalid instruction",
      exec: invalidOp,
    ),
    (
      opCode: SelfDestruct, ## 0xff, Halt execution, prep for later deletion
      forks: VmOpAllForks - VmOpTangerineAndLater,
      name: "selfDestruct",
      info: "Halt execution and register account for later deletion",
      exec: selfDestructOp,
    ),
    (
      opCode: SelfDestruct, ## 0xff, EIP150: self destruct, Tangerine
      forks: VmOpTangerineAndLater - VmOpSpuriousAndLater,
      name: "selfDestructEIP150",
      info: "EIP150: Halt execution and register account for later deletion",
      exec: selfDestructEIP150Op,
    ),
    (
      opCode: SelfDestruct, ## 0xff, EIP161: self destruct, Spurious and later
      forks: VmOpSpuriousAndLater - VmOpBerlinAndLater,
      name: "selfDestructEIP161",
      info: "EIP161: Halt execution and register account for later deletion",
      exec: selfDestructEIP161Op,
    ),
    (
      opCode: SelfDestruct, ## 0xff, EIP2929: self destruct, Berlin and later
      forks: VmOpBerlinAndLater,
      name: "selfDestructEIP2929",
      info: "EIP2929: Halt execution and register account for later deletion",
      exec: selfDestructEIP2929Op,
    ),
  ]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
