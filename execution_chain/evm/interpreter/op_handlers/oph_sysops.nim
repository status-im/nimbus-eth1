# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
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
    ../../../core/eip8037,
  ../../evm_errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_meter,
  ../gas_costs,
  ../op_codes,
  ./oph_defs,
  ./oph_helpers,
  ../../state,
  ../../../db/ledger,
  ../../../constants

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

proc returnOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf3, Halt execution returning output data.
  ? cpt.stack.lsCheck(2)
  let
    pos = cpt.stack.lsPeekMemRef(^1)
    len = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(2)

  ? cpt.opcodeGasCost(Return,
    cpt.gasCosts[Return].m_handler(cpt.memory.len, pos, len),
    reason = "RETURN")

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))
  ok()


proc revertOp(cpt: VmCpt): EvmResultVoid =
  ## 0xfd, Halt execution reverting state changes but returning data
  ##       and remaining gas.
  ? cpt.stack.lsCheck(2)
  let
    pos = cpt.stack.lsPeekMemRef(^1)
    len = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(2)

  ? cpt.opcodeGasCost(Revert,
      cpt.gasCosts[Revert].m_handler(cpt.memory.len, pos, len),
      reason = "REVERT")

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))

  let revertReason = unpackRevertReason(cpt.output)

  let revertMsg =
    if revertReason.isSome:
      "execution reverted: " & revertReason.value
    else:
      "execution reverted"

  # setError(msg, false) will signal cheap revert
  cpt.setError(StatusCode.Revert, revertMsg, false)

  ok()

func invalidOp(cpt: VmCpt): EvmResultVoid =
  err(opErr(InvalidInstruction))

# -----------

proc selfDestructOp(cpt: VmCpt): EvmResultVoid =
  ## 0xff, Halt execution and register account for later deletion.
  let beneficiary = ? cpt.stack.popAddress()

  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP150Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEip150 (auto generated comment)
  let
    beneficiary = ? cpt.stack.popAddress()
    condition = not cpt.accountExistsOrAlive(beneficiary)
    gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  ? cpt.opcodeGasCost(SelfDestruct,
    gasCost, reason = "SELFDESTRUCT EIP-150")
  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP161Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEip161 (auto generated comment)
  ? cpt.checkInStaticContext()

  let
    beneficiary = ? cpt.stack.popAddress()
    isDead      = not cpt.accountExistsOrAlive(beneficiary)
    balance     = cpt.getBalance(cpt.msg.currentTarget)
    condition   = isDead and not balance.isZero
    gasCost     = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  ? cpt.opcodeGasCost(SelfDestruct,
    gasCost, reason = "SELFDESTRUCT EIP-161")
  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEIP2929 (auto generated comment)
  ? cpt.checkInStaticContext()

  let beneficiary = ? cpt.stack.popAddress()

  var beneficiaryIsCold = false
  cpt.vmState.mutateLedger:
    if not ledger.inAccessList(beneficiary):
      beneficiaryIsCold = true

  var staticGasCosts = cpt.gasCosts[SelfDestruct].sc_handler(false)
  if beneficiaryIsCold:
    staticGasCosts += COLD_ACCOUNT_ACCESS_2929
  if staticGasCosts > cpt.gasMeter.executionGasLeft:
    return EvmResultVoid.err(gasErr(OutOfGas))

  let
    isDead = not cpt.accountExistsOrAlive(beneficiary)
    balance = cpt.getBalance(cpt.msg.currentTarget)
    condition = isDead and not balance.isZero

  var gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  cpt.vmState.mutateLedger:
    if beneficiaryIsCold:
      ledger.accessList(beneficiary)
      gasCost = gasCost + COLD_ACCOUNT_ACCESS_2929

  ? cpt.opcodeGasCost(SelfDestruct,
    gasCost, reason = "SELFDESTRUCT EIP-2929")
  cpt.selfDestruct(beneficiary)
  ok()

proc selfDestructEIP8037Op(cpt: VmCpt): EvmResultVoid =
  ## selfDestructEIP2929 (auto generated comment)
  ? cpt.checkInStaticContext()

  let beneficiary = ? cpt.stack.popAddress()

  var beneficiaryIsCold = false
  cpt.vmState.mutateLedger:
    if not ledger.inAccessList(beneficiary):
      beneficiaryIsCold = true

  var staticGasCosts = cpt.gasCosts[SelfDestruct].sc_handler(false)
  if beneficiaryIsCold:
    staticGasCosts += COLD_ACCOUNT_ACCESS_8038
  if staticGasCosts > cpt.gasMeter.executionGasLeft:
    return EvmResultVoid.err(gasErr(OutOfGas))

  let
    isNewAccount = not cpt.accountExistsOrAlive(beneficiary)
    balance = cpt.getBalance(cpt.msg.currentTarget)
    condition = isNewAccount and not balance.isZero

  var gasCost = cpt.gasCosts[SelfDestruct].sc_handler(condition)

  cpt.vmState.mutateLedger:
    if beneficiaryIsCold:
      ledger.accessList(beneficiary)
      gasCost += COLD_ACCOUNT_ACCESS_8038

  # Charge execution gas before state gas so that a execution-gas OOG
  # does not consume state gas that would inflate the parent's
  # reservoir on frame failure.
  ? cpt.opcodeGasCost(SelfDestruct,
    gasCost, reason = "SELFDESTRUCT EIP-8037")

  if condition:
    ? cpt.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS,
      reason = "SELFDESTRUCT EIP-8037: State gas new account")

  cpt.selfDestruct(beneficiary)
  ok()

proc setCodeFromOp(cpt: VmCpt): EvmResultVoid =
  ## 0xA7, EIP8298: Code Reuse Instruction
  ? cpt.checkInStaticContext()

  if cpt.msg.currentTarget in SYSTEM_CONTRACTS:
    return err(opErr(CodeChangeInSystemContract))

  ? cpt.stack.lsCheck(1)

  let
    source = cpt.stack.lsPeekAddress(^1)
    ledger = cpt.vmState.ledger
    isColdAccess = not ledger.inAccessList(source)

  var
    accessGasCost = WARM_ACCESS.GasInt

  if isColdAccess:
    accessGasCost += COLD_ACCOUNT_ACCESS_8038
  else:
    accessGasCost += WARM_ACCESS

  ? cpt.gasMeter.checkGas(accessGasCost)

  if isColdAccess:
    ledger.accessList(source)

  var
    newCodeHash = Opt.none(Hash32)

  if cpt.balTrackerEnabled:
    cpt.vmState.balTracker.trackAddressAccess(source)

  let
    sourceCodeHash = ledger.canAdoptCode(source).valueOr:
      cpt.stack.lsTop 0.u256
      return ok()

  accessGasCost += WARM_ACCESS
  ? cpt.gasMeter.checkGas(accessGasCost)

  let
    currentCodeHash = ledger.getCodeHash(cpt.msg.currentTarget)

  if currentCodeHash != sourceCodeHash:
    accessGasCost += ACCOUNT_WRITE_8038
    ? cpt.gasMeter.checkGas(accessGasCost)
    newCodeHash = Opt.some(sourceCodeHash)

  ? cpt.opcodeGasCost(SetCodeFrom,
    accessGasCost, reason = "SetCodeFrom EIP-8298")

  if newCodeHash.isSome:
    if cpt.balTrackerEnabled:
      cpt.vmState.balTracker.trackAdoptCode(cpt.msg.currentTarget, newCodeHash.value)
    ledger.adoptCode(cpt.msg.currentTarget, newCodeHash.value)

  cpt.stack.lsTop 1.u256
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
     exec: returnOp),


    (opCode: Revert,       ## 0xfd, Halt and revert state changes
     forks: VmOpByzantiumAndLater,
     name: "revert",
     info: "Halt execution reverting state changes but returning data " &
           "and remaining gas",
     exec: revertOp),


    (opCode: Invalid,      ## 0xfe, invalid instruction.
     forks: VmOpAllForks,
     name: "invalidInstruction",
     info: "Designated invalid instruction",
     exec: invalidOp),


    (opCode: SelfDestruct, ## 0xff, Halt execution, prep for later deletion
     forks: VmOpAllForks - VmOpTangerineAndLater,
     name: "selfDestruct",
     info: "Halt execution and register account for later deletion",
     exec: selfDestructOp),


    (opCode: SelfDestruct, ## 0xff, EIP150: self destruct, Tangerine
     forks: VmOpTangerineAndLater - VmOpSpuriousAndLater,
     name: "selfDestructEIP150",
     info: "EIP150: Halt execution and register account for later deletion",
     exec: selfDestructEIP150Op),


    (opCode: SelfDestruct, ## 0xff, EIP161: self destruct, Spurious and later
     forks: VmOpSpuriousAndLater - VmOpBerlinAndLater,
     name: "selfDestructEIP161",
     info: "EIP161: Halt execution and register account for later deletion",
     exec: selfDestructEIP161Op),


    (opCode: SelfDestruct, ## 0xff, EIP2929: self destruct, Berlin and later
     forks: VmOpBerlinAndLater - VmOpAmsterdamAndLater,
     name: "selfDestructEIP2929",
     info: "EIP2929: Halt execution and register account for later deletion",
     exec: selfDestructEIP2929Op),


    (opCode: SelfDestruct, ## 0xff, EIP2929: self destruct, Berlin and later
     forks: VmOpAmsterdamAndLater,
     name: "selfDestructEIP8037",
     info: "EIP8037: Halt execution and register account for later deletion",
     exec: selfDestructEIP8037Op),


    (opCode: SetCodeFrom,  ## 0xA7, EIP8298: Code Reuse Instruction
     forks: VmOpBogotaAndLater,
     name: "setCodeFrom",
     info: "EIP8298: Code Reuse Instruction",
     exec: setCodeFromOp)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
