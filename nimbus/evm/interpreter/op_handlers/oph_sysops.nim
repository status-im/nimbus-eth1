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
  ../../../errors,
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

# Annotation helpers
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

const
  returnOp: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## 0xf3, Halt execution returning output data.
    let (startPos, size) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
    k.cpt.opcodeGastCost(Return,
      k.cpt.gasCosts[Return].m_handler(k.cpt.memory.len, pos, len),
      reason = "RETURN")
    k.cpt.memory.extend(pos, len)
    k.cpt.output = k.cpt.memory.read(pos, len)


  revertOp: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## 0xfd, Halt execution reverting state changes but returning data
    ##       and remaining gas.
    let (startPos, size) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
    k.cpt.opcodeGastCost(Revert,
      k.cpt.gasCosts[Revert].m_handler(k.cpt.memory.len, pos, len),
      reason = "REVERT")

    k.cpt.memory.extend(pos, len)
    k.cpt.output = k.cpt.memory.read(pos, len)
    # setError(msg, false) will signal cheap revert
    k.cpt.setError(EVMC_REVERT, "REVERT opcode executed", false)


  invalidOp: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    raise newException(InvalidInstruction,
                       "Invalid instruction, received an opcode " &
                         "not implemented in the current fork. " &
                          $k.cpt.fork & " " & $k.cpt.instr)

  # -----------

  selfDestructOp: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## 0xff, Halt execution and register account for later deletion.
    let cpt = k.cpt
    let beneficiary = cpt.stack.popAddress()
    when defined(evmc_enabled):
      block:
        cpt.selfDestruct(beneficiary)
    else:
      block:
        cpt.selfDestruct(beneficiary)


  selfDestructEIP150Op: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## selfDestructEip150 (auto generated comment)
    let cpt = k.cpt
    let beneficiary = cpt.stack.popAddress()
    block:
      let gasParams = GasParams(
        kind: SelfDestruct,
        sd_condition: not cpt.accountExists(beneficiary))

      let gasCost =
        cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
      cpt.opcodeGastCost(SelfDestruct,
        gasCost, reason = "SELFDESTRUCT EIP150")
      cpt.selfDestruct(beneficiary)


  selfDestructEIP161Op: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## selfDestructEip161 (auto generated comment)
    let cpt = k.cpt
    checkInStaticContext(cpt)

    let beneficiary = cpt.stack.popAddress()
    block:
      let
        isDead = not cpt.accountExists(beneficiary)
        balance = cpt.getBalance(cpt.msg.contractAddress)

      let gasParams = GasParams(
        kind: SelfDestruct,
        sd_condition: isDead and not balance.isZero)

      let gasCost =
        cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
      cpt.opcodeGastCost(SelfDestruct,
        gasCost, reason = "SELFDESTRUCT EIP161")
      cpt.selfDestruct(beneficiary)


  selfDestructEIP2929Op: Vm2OpFn = proc(k: var Vm2Ctx) {.catchRaise.} =
    ## selfDestructEIP2929 (auto generated comment)
    let cpt = k.cpt
    checkInStaticContext(cpt)

    let beneficiary = cpt.stack.popAddress()
    block:
      let
        isDead = not cpt.accountExists(beneficiary)
        balance = cpt.getBalance(cpt.msg.contractAddress)

      let gasParams = GasParams(
        kind: SelfDestruct,
        sd_condition: isDead and not balance.isZero)

      var gasCost =
        cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost

      when evmc_enabled:
        if cpt.host.accessAccount(beneficiary) == EVMC_ACCESS_COLD:
          gasCost = gasCost + ColdAccountAccessCost
      else:
        cpt.vmState.mutateStateDB:
          if not db.inAccessList(beneficiary):
            db.accessList(beneficiary)
            gasCost = gasCost + ColdAccountAccessCost

      cpt.opcodeGastCost(SelfDestruct,
        gasCost, reason = "SELFDESTRUCT EIP2929")
      cpt.selfDestruct(beneficiary)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecSysOp*: seq[Vm2OpExec] = @[

    (opCode: Return,       ## 0xf3, Halt execution returning output data.
     forks: Vm2OpAllForks,
     name: "returnOp",
     info: "Halt execution returning output data",
     exec: (prep: vm2OpIgnore,
            run: returnOp,
            post: vm2OpIgnore)),

    (opCode: Revert,       ## 0xfd, Halt and revert state changes
     forks: Vm2OpByzantiumAndLater,
     name: "revert",
     info: "Halt execution reverting state changes but returning data " &
           "and remaining gas",
     exec: (prep: vm2OpIgnore,
            run: revertOp,
            post: vm2OpIgnore)),

    (opCode: Invalid,      ## 0xfe, invalid instruction.
     forks: Vm2OpAllForks,
     name: "invalidInstruction",
     info: "Designated invalid instruction",
     exec: (prep: vm2OpIgnore,
            run: invalidOp,
            post: vm2OpIgnore)),

    (opCode: SelfDestruct, ## 0xff, Halt execution, prep for later deletion
     forks: Vm2OpAllForks - Vm2OpTangerineAndLater,
     name: "selfDestruct",
     info: "Halt execution and register account for later deletion",
     exec: (prep: vm2OpIgnore,
            run:  selfDestructOp,
            post: vm2OpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP150: self destruct, Tangerine
     forks: Vm2OpTangerineAndLater - Vm2OpSpuriousAndLater,
     name: "selfDestructEIP150",
     info: "EIP150: Halt execution and register account for later deletion",
     exec: (prep: vm2OpIgnore,
            run:  selfDestructEIP150Op,
            post: vm2OpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP161: self destruct, Spurious and later
     forks: Vm2OpSpuriousAndLater - Vm2OpBerlinAndLater,
     name: "selfDestructEIP161",
     info: "EIP161: Halt execution and register account for later deletion",
     exec: (prep: vm2OpIgnore,
            run:  selfDestructEIP161Op,
            post: vm2OpIgnore)),

    (opCode: SelfDestruct, ## 0xff, EIP2929: self destruct, Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "selfDestructEIP2929",
     info: "EIP2929: Halt execution and register account for later deletion",
     exec: (prep: vm2OpIgnore,
            run:  selfDestructEIP2929Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
