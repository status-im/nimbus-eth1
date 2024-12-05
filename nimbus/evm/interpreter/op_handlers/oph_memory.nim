# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Stack, Memory, Storage And Flow Operations
## ===============================================================
##

{.push raises: [].}

import
  ../../evm_errors,
  ../../code_stream,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_meter,
  ../gas_costs,
  ../op_codes,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stint

when not defined(evmc_enabled):
  import
    ../../state,
    ../../../db/ledger
else:
  import
    ../evmc_gas_costs

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when evmc_enabled:
  proc sstoreEvmc(c: Computation, slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid =
    let
      status  = c.host.setStorage(c.msg.contractAddress, slot, newValue)
      res     = ForkToSstoreCost[c.fork][status]
      gasCost = res.gasCost.GasInt + coldAccess

    ? c.opcodeGasCost(Sstore, gasCost, "SSTORE")
    c.gasMeter.refundGas(res.gasRefund)
    ok()

else:
  proc sstoreImpl(c: Computation, slot, newValue: UInt256): EvmResultVoid =
    let
      currentValue = c.getStorage(slot)
      gasParam = GasParamsSs(
        currentValue: currentValue)
      res = c.gasCosts[Sstore].ss_handler(newValue, gasParam)

    ? c.opcodeGasCost(Sstore, res.gasCost, "SSTORE")
    c.gasMeter.refundGas(res.gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)
    ok()


  proc sstoreNetGasMeteringImpl(c: Computation; slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid =
    let
      stateDB = c.vmState.readOnlyStateDB
      currentValue = c.getStorage(slot)

      gasParam = GasParamsSs(
        currentValue: currentValue,
        originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot))

      res = c.gasCosts[Sstore].ss_handler(newValue, gasParam)

    ? c.opcodeGasCost(Sstore, res.gasCost + coldAccess, "SSTORE")

    c.gasMeter.refundGas(res.gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)
    ok()

template sstoreEvmcOrSstore(cpt, slot, newValue: untyped): auto =
  when evmc_enabled:
    sstoreEvmc(cpt, slot, newValue, 0.GasInt)
  else:
    sstoreImpl(cpt, slot, newValue)

template sstoreEvmcOrNetGasMetering(cpt, slot, newValue: untyped, coldAccess = 0.GasInt): auto =
  when evmc_enabled:
    sstoreEvmc(cpt, slot, newValue, coldAccess)
  else:
    sstoreNetGasMeteringImpl(cpt, slot, newValue, coldAccess)

func jumpImpl(c: Computation; jumpTarget: UInt256): EvmResultVoid =
  if jumpTarget >= c.code.len.u256:
    return err(opErr(InvalidJumpDest))

  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != JumpDest:
    return err(opErr(InvalidJumpDest))

  # Jump destination must be a valid opcode
  if not c.code.isValidOpcode(jt):
    return err(opErr(InvalidJumpDest))

  ok()

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc popOp(cpt: VmCpt): EvmResultVoid =
  ## 0x50, Remove item from stack.
  cpt.stack.pop()

proc mloadOp(cpt: VmCpt): EvmResultVoid =
  ## 0x51, Load word from memory

  ? cpt.stack.lsCheck(1)
  let memPos = cpt.stack.lsPeekMemRef(^1)

  ? cpt.opcodeGasCost(Mload,
    cpt.gasCosts[Mload].m_handler(cpt.memory.len, memPos, 32),
    reason = "MLOAD: GasVeryLow + memory expansion")

  cpt.memory.extend(memPos, 32)
  cpt.stack.lsTop cpt.memory.read32Bytes(memPos)
  ok()


proc mstoreOp(cpt: VmCpt): EvmResultVoid =
  ## 0x52, Save word to memory
  ? cpt.stack.lsCheck(2)
  let
    memPos = cpt.stack.lsPeekMemRef(^1)
    value  = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? cpt.opcodeGasCost(Mstore,
    cpt.gasCosts[Mstore].m_handler(cpt.memory.len, memPos, 32),
    reason = "MSTORE: GasVeryLow + memory expansion")

  cpt.memory.extend(memPos, 32)
  cpt.memory.write(memPos, value.toBytesBE)


proc mstore8Op(cpt: VmCpt): EvmResultVoid =
  ## 0x53, Save byte to memory
  ? cpt.stack.lsCheck(2)
  let
    memPos = cpt.stack.lsPeekMemRef(^1)
    value  = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? cpt.opcodeGasCost(Mstore8,
    cpt.gasCosts[Mstore8].m_handler(cpt.memory.len, memPos, 1),
    reason = "MSTORE8: GasVeryLow + memory expansion")

  cpt.memory.extend(memPos, 1)
  cpt.memory.write(memPos, value.toBytesBE[31])


# -------

proc sloadOp(cpt: VmCpt): EvmResultVoid =
  ## 0x54, Load word from storage.
  template sload256(top, slot, conv) =
    conv(cpt.getStorage(slot), top)
  cpt.stack.unaryWithTop(sload256)

proc sloadEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x54, EIP2929: Load word from storage for Berlin and later
  template sloadEIP2929(top, slot, conv) =
    let gasCost = cpt.gasEip2929AccountCheck(cpt.msg.contractAddress, slot)
    ? cpt.opcodeGasCost(Sload, gasCost, reason = "sloadEIP2929")
    conv(cpt.getStorage(slot), top)
  cpt.stack.unaryWithTop(sloadEIP2929)

# -------

proc sstoreOp(cpt: VmCpt): EvmResultVoid =
  ## 0x55, Save word to storage.
  ? cpt.stack.lsCheck(2)
  let
    slot = cpt.stack.lsPeekInt(^1)
    newValue = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? checkInStaticContext(cpt)
  sstoreEvmcOrSstore(cpt, slot, newValue)


proc sstoreEIP1283Op(cpt: VmCpt): EvmResultVoid =
  ## 0x55, EIP1283: sstore for Constantinople and later
  ? cpt.stack.lsCheck(2)
  let
    slot = cpt.stack.lsPeekInt(^1)
    newValue = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? checkInStaticContext(cpt)
  sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


proc sstoreEIP2200Op(cpt: VmCpt): EvmResultVoid =
  ## 0x55, EIP2200: sstore for Istanbul and later
  ? cpt.stack.lsCheck(2)
  let
    slot = cpt.stack.lsPeekInt(^1)
    newValue = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? checkInStaticContext(cpt)
  const SentryGasEIP2200 = 2300

  if cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
    return err(opErr(OutOfGas))

  sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


proc sstoreEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x55, EIP2929: sstore for Berlin and later
  ? cpt.stack.lsCheck(2)
  let
    slot = cpt.stack.lsPeekInt(^1)
    newValue = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  ? checkInStaticContext(cpt)

  # Minimum gas required to be present for an SSTORE call, not consumed
  const SentryGasEIP2200 = 2300

  if cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
    return err(opErr(OutOfGas))

  var coldAccessGas = 0.GasInt
  when evmc_enabled:
    if cpt.host.accessStorage(cpt.msg.contractAddress, slot) == EVMC_ACCESS_COLD:
      coldAccessGas = ColdSloadCost
  else:
    cpt.vmState.mutateStateDB:
      if not db.inAccessList(cpt.msg.contractAddress, slot):
        db.accessList(cpt.msg.contractAddress, slot)
        coldAccessGas = ColdSloadCost

  sstoreEvmcOrNetGasMetering(cpt, slot, newValue, coldAccessGas)

# -------

proc jumpOp(cpt: VmCpt): EvmResultVoid =
  ## 0x56, Alter the program counter
  let jumpTarget = ? cpt.stack.popInt()
  cpt.jumpImpl(jumpTarget)


proc jumpIOp(cpt: VmCpt): EvmResultVoid =
  ## 0x57, Conditionally alter the program counter.
  ? cpt.stack.lsCheck(2)
  let
    jumpTarget  = cpt.stack.lsPeekInt(^1)
    testedValue = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  if testedValue.isZero:
    return ok()
  cpt.jumpImpl(jumpTarget)

proc pcOp(cpt: VmCpt): EvmResultVoid =
  ## 0x58, Get the value of the program counter prior to the increment
  ##       corresponding to this instruction.
  cpt.stack.push max(cpt.code.pc - 1, 0)

proc msizeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x59, Get the size of active memory in bytes.
  cpt.stack.push cpt.memory.len

proc gasOp(cpt: VmCpt): EvmResultVoid =
  ## 0x5a, Get the amount of available gas, including the corresponding
  ##       reduction for the cost of this instruction.
  cpt.stack.push cpt.gasMeter.gasRemaining

proc jumpDestOp(cpt: VmCpt): EvmResultVoid =
  ## 0x5b, Mark a valid destination for jumps. This operation has no effect
  ##       on machine state during execution.
  ok()

proc tloadOp(cpt: VmCpt): EvmResultVoid =
  ## 0x5c, Load word from transient storage.
  ? cpt.stack.lsCheck(1)
  let
    slot = cpt.stack.lsPeekInt(^1)
    val  = cpt.getTransientStorage(slot)
  cpt.stack.lsTop val
  ok()

proc tstoreOp(cpt: VmCpt): EvmResultVoid =
  ## 0x5d, Save word to transient storage.
  ? cpt.checkInStaticContext()

  ? cpt.stack.lsCheck(2)
  let
    slot = cpt.stack.lsPeekInt(^1)
    val  = cpt.stack.lsPeekInt(^2)
  cpt.stack.lsShrink(2)

  cpt.setTransientStorage(slot, val)
  ok()

proc mCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x5e, Copy memory
  ? cpt.stack.lsCheck(3)
  let
    dstPos = cpt.stack.lsPeekMemRef(^1)
    srcPos = cpt.stack.lsPeekMemRef(^2)
    len    = cpt.stack.lsPeekMemRef(^3)
  cpt.stack.lsShrink(3)

  ? cpt.opcodeGasCost(Mcopy,
    cpt.gasCosts[Mcopy].m_handler(cpt.memory.len, max(dstPos, srcPos), len),
    reason = "Mcopy fee")

  cpt.memory.copy(dstPos, srcPos, len)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecMemory*: seq[VmOpExec] = @[

    (opCode: Pop,       ## x50, Remove item from stack
     forks: VmOpAllForks,
     name: "pop",
     info: "Remove item from stack",
     exec: VmOpFn popOp),


    (opCode: Mload,     ## 0x51, Load word from memory
     forks: VmOpAllForks,
     name: "mload",
     info: "Load word from memory",
     exec: mloadOp),


    (opCode: Mstore,    ## 0x52, Save word to memory
     forks: VmOpAllForks,
     name: "mstore",
     info: "Save word to memory",
     exec: mstoreOp),


    (opCode: Mstore8,   ## 0x53, Save byte to memory
     forks: VmOpAllForks,
     name: "mstore8",
     info: "Save byte to memory",
     exec: mstore8Op),


    (opCode: Sload,     ## 0x54, Load word from storage
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "sload",
     info: "Load word from storage",
     exec: sloadOp),


    (opCode: Sload,     ## 0x54, sload for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "sloadEIP2929",
     info: "EIP2929: sload for Berlin and later",
     exec: sloadEIP2929Op),


    (opCode: Sstore,    ## 0x55, Save word
     forks: VmOpAllForks - VmOpConstantinopleAndLater,
     name: "sstore",
     info: "Save word to storage",
     exec: sstoreOp),


    (opCode: Sstore,    ## 0x55, sstore for Constantinople and later
     forks: VmOpConstantinopleAndLater - VmOpPetersburgAndLater,
     name: "sstoreEIP1283",
     info: "EIP1283: sstore for Constantinople and later",
     exec: sstoreEIP1283Op),


    (opCode: Sstore,    ## 0x55, sstore for Petersburg and later
     forks: VmOpPetersburgAndLater - VmOpIstanbulAndLater,
     name: "sstore",
     info: "sstore for Constantinople and later",
     exec: sstoreOp),


    (opCode: Sstore,    ##  0x55, sstore for Istanbul and later
     forks: VmOpIstanbulAndLater - VmOpBerlinAndLater,
     name: "sstoreEIP2200",
     info: "EIP2200: sstore for Istanbul and later",
     exec: sstoreEIP2200Op),


    (opCode: Sstore,    ##  0x55, sstore for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "sstoreEIP2929",
     info: "EIP2929: sstore for Istanbul and later",
     exec: sstoreEIP2929Op),


    (opCode: Jump,      ## 0x56, Jump
     forks: VmOpAllForks,
     name: "jump",
     info: "Alter the program counter",
     exec: jumpOp),


    (opCode: JumpI,     ## 0x57, Conditional jump
     forks: VmOpAllForks,
     name: "jumpI",
     info: "Conditionally alter the program counter",
     exec: jumpIOp),


    (opCode: Pc,        ## 0x58, Program counter prior to instruction
     forks: VmOpAllForks,
     name: "pc",
     info: "Get the value of the program counter prior to the increment "&
           "corresponding to this instruction",
     exec: pcOp),


    (opCode: Msize,     ## 0x59, Memory size
     forks: VmOpAllForks,
     name: "msize",
     info: "Get the size of active memory in bytes",
     exec: msizeOp),


    (opCode: Gas,       ##  0x5a, Get available gas
     forks: VmOpAllForks,
     name: "gas",
     info: "Get the amount of available gas, including the corresponding "&
           "reduction for the cost of this instruction",
     exec: gasOp),


    (opCode: JumpDest,  ## 0x5b, Mark jump target. This operation has no effect
                        ##       on machine state during execution
     forks: VmOpAllForks,
     name: "jumpDest",
     info: "Mark a valid destination for jumps",
     exec: jumpDestOp),


    (opCode: Tload,     ## 0x5c, Load word from transient storage.
     forks: VmOpCancunAndLater,
     name: "tLoad",
     info: "Load word from transient storage",
     exec: tloadOp),


    (opCode: Tstore,     ## 0x5d, Save word to transient storage.
     forks: VmOpCancunAndLater,
     name: "tStore",
     info: "Save word to transient storage",
     exec: tstoreOp),


    (opCode: Mcopy,     ## 0x5e, Copy memory
     forks: VmOpCancunAndLater,
     name: "MCopy",
     info: "Copy memory",
     exec: mCopyOp)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
