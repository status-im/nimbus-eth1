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
  ../gas_costs,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stint

when not defined(evmc_enabled):
  import
    ../gas_meter,
    ../../state,
    ../../../db/ledger

# Annotation helpers
{.pragma: catchRaise, gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when evmc_enabled:
  proc sstoreEvmc(c: Computation, slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid {.catchRaise.} =
    let
      status   = c.host.setStorage(c.msg.contractAddress, slot, newValue)
      gasParam = GasParams(kind: Op.Sstore, s_status: status)
      gasCost  = c.gasCosts[Sstore].c_handler(newValue, gasParam)[0] + coldAccess

    c.opcodeGastCost(Sstore, gasCost, "SSTORE")

else:
  proc sstoreImpl(c: Computation, slot, newValue: UInt256): EvmResultVoid {.catchRaise.} =
    let
      currentValue = c.getStorage(slot)
      gasParam = GasParams(
        kind: Op.Sstore,
        s_currentValue: currentValue)

      res = ? c.gasCosts[Sstore].c_handler(newValue, gasParam)

    ? c.opcodeGastCost(Sstore, res.gasCost, "SSTORE")
    if res.gasRefund > 0:
      c.gasMeter.refundGas(res.gasRefund)

    c.vmState.mutateStateDB:
      db.setStorage(c.msg.contractAddress, slot, newValue)
    ok()


  proc sstoreNetGasMeteringImpl(c: Computation; slot, newValue: UInt256, coldAccess = 0.GasInt): EvmResultVoid {.catchRaise.} =
    let
      stateDB = c.vmState.readOnlyStateDB
      currentValue = c.getStorage(slot)

      gasParam = GasParams(
        kind: Op.Sstore,
        s_currentValue: currentValue,
        s_originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot))

      res = ? c.gasCosts[Sstore].c_handler(newValue, gasParam)

    ? c.opcodeGastCost(Sstore, res.gasCost + coldAccess, "SSTORE")

    if res.gasRefund != 0:
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

func jumpImpl(c: Computation; jumpTarget: UInt256): EvmResultVoid {.catchRaise.} =
  if jumpTarget >= c.code.len.u256:
    return err(opErr(InvalidJumpDest))

  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != JumpDest:
    return err(opErr(InvalidJumpDest))

  # TODO: next check seems redundant
  if not c.code.isValidOpcode(jt):
    return err(opErr(InvalidJumpDest))

  ok()

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  popOp: Vm2OpFn = func (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x50, Remove item from stack.
    k.cpt.stack.popInt.isOkOr:
      return err(error)
    ok()

  mloadOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x51, Load word from memory
    let memStartPos = ? k.cpt.stack.popInt()

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mload,
      k.cpt.gasCosts[Mload].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MLOAD: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.stack.push k.cpt.memory.read32Bytes(memPos)


  mstoreOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x52, Save word to memory
    let (memStartPos, value) = ? k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mstore,
      k.cpt.gasCosts[Mstore].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MSTORE: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.memory.write(memPos, value.toBytesBE)


  mstore8Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x53, Save byte to memory
    let (memStartPos, value) = ? k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    ? k.cpt.opcodeGastCost(Mstore8,
      k.cpt.gasCosts[Mstore8].m_handler(k.cpt.memory.len, memPos, 1),
      reason = "MSTORE8: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 1)
    k.cpt.memory.write(memPos, value.toByteArrayBE[31])


  # -------

  sloadOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x54, Load word from storage.
    let
      cpt = k.cpt
      slot = ? cpt.stack.popInt()
    cpt.stack.push cpt.getStorage(slot)

  sloadEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x54, EIP2929: Load word from storage for Berlin and later
    let
      cpt = k.cpt
      slot = ? cpt.stack.popInt()
      gasCost = cpt.gasEip2929AccountCheck(cpt.msg.contractAddress, slot)
    ? cpt.opcodeGastCost(Sload, gasCost, reason = "sloadEIP2929")
    cpt.stack.push cpt.getStorage(slot)

  # -------

  sstoreOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x55, Save word to storage.
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    sstoreEvmcOrSstore(cpt, slot, newValue)


  sstoreEIP1283Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x55, EIP1283: sstore for Constantinople and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


  sstoreEIP2200Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x55, EIP2200: sstore for Istanbul and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

    ? checkInStaticContext(cpt)
    const SentryGasEIP2200 = 2300

    if cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
      return err(opErr(OutOfGas))

    sstoreEvmcOrNetGasMetering(cpt, slot, newValue)


  sstoreEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x55, EIP2929: sstore for Berlin and later
    let
      cpt = k.cpt
      (slot, newValue) = ? cpt.stack.popInt(2)

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

  jumpOp: Vm2OpFn = func (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x56, Alter the program counter
    let jumpTarget = ? k.cpt.stack.popInt()
    jumpImpl(k.cpt, jumpTarget)


  jumpIOp: Vm2OpFn = func (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x57, Conditionally alter the program counter.
    let (jumpTarget, testedValue) = ? k.cpt.stack.popInt(2)
    if testedValue.isZero:
      return ok()
    jumpImpl(k.cpt, jumpTarget)

  pcOp: Vm2OpFn = func (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x58, Get the value of the program counter prior to the increment
    ##       corresponding to this instruction.
    k.cpt.stack.push max(k.cpt.code.pc - 1, 0)

  msizeOp: Vm2OpFn = func (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x59, Get the size of active memory in bytes.
    k.cpt.stack.push k.cpt.memory.len

  gasOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x5a, Get the amount of available gas, including the corresponding
    ##       reduction for the cost of this instruction.
    k.cpt.stack.push k.cpt.gasMeter.gasRemaining

  jumpDestOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x5b, Mark a valid destination for jumps. This operation has no effect
    ##       on machine state during execution.
    ok()

  tloadOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x5c, Load word from transient storage.
    let
      slot = ? k.cpt.stack.popInt()
      val  = k.cpt.getTransientStorage(slot)
    k.cpt.stack.push val

  tstoreOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x5d, Save word to transient storage.
    ? checkInStaticContext(k.cpt)

    let
      slot = ? k.cpt.stack.popInt()
      val  = ? k.cpt.stack.popInt()
    k.cpt.setTransientStorage(slot, val)
    ok()

  mCopyOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid {.catchRaise.} =
    ## 0x5e, Copy memory
    let (dst, src, size) = ? k.cpt.stack.popInt(3)

    let (dstPos, srcPos, len) =
      (dst.cleanMemRef, src.cleanMemRef, size.cleanMemRef)

    ? k.cpt.opcodeGastCost(Mcopy,
      k.cpt.gasCosts[Mcopy].m_handler(k.cpt.memory.len, max(dstPos, srcPos), len),
      reason = "Mcopy fee")

    k.cpt.memory.copy(dstPos, srcPos, len)
    ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecMemory*: seq[Vm2OpExec] = @[

    (opCode: Pop,       ## x50, Remove item from stack
     forks: Vm2OpAllForks,
     name: "pop",
     info: "Remove item from stack",
     exec: (prep: vm2OpIgnore,
            run:  popOp,
            post: vm2OpIgnore)),

    (opCode: Mload,     ## 0x51, Load word from memory
     forks: Vm2OpAllForks,
     name: "mload",
     info: "Load word from memory",
     exec: (prep: vm2OpIgnore,
            run:  mloadOp,
            post: vm2OpIgnore)),

    (opCode: Mstore,    ## 0x52, Save word to memory
     forks: Vm2OpAllForks,
     name: "mstore",
     info: "Save word to memory",
     exec: (prep: vm2OpIgnore,
            run:  mstoreOp,
            post: vm2OpIgnore)),

    (opCode: Mstore8,   ## 0x53, Save byte to memory
     forks: Vm2OpAllForks,
     name: "mstore8",
     info: "Save byte to memory",
     exec: (prep: vm2OpIgnore,
            run:  mstore8Op,
            post: vm2OpIgnore)),

    (opCode: Sload,     ## 0x54, Load word from storage
     forks: Vm2OpAllForks - Vm2OpBerlinAndLater,
     name: "sload",
     info: "Load word from storage",
     exec: (prep: vm2OpIgnore,
            run:  sloadOp,
            post: vm2OpIgnore)),

    (opCode: Sload,     ## 0x54, sload for Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "sloadEIP2929",
     info: "EIP2929: sload for Berlin and later",
     exec: (prep: vm2OpIgnore,
            run:  sloadEIP2929Op,
            post: vm2OpIgnore)),

    (opCode: Sstore,    ## 0x55, Save word
     forks: Vm2OpAllForks - Vm2OpConstantinopleAndLater,
     name: "sstore",
     info: "Save word to storage",
     exec: (prep: vm2OpIgnore,
            run:  sstoreOp,
            post: vm2OpIgnore)),

    (opCode: Sstore,    ## 0x55, sstore for Constantinople and later
     forks: Vm2OpConstantinopleAndLater - Vm2OpPetersburgAndLater,
     name: "sstoreEIP1283",
     info: "EIP1283: sstore for Constantinople and later",
     exec: (prep: vm2OpIgnore,
            run:  sstoreEIP1283Op,
            post: vm2OpIgnore)),

    (opCode: Sstore,    ## 0x55, sstore for Petersburg and later
     forks: Vm2OpPetersburgAndLater - Vm2OpIstanbulAndLater,
     name: "sstore",
     info: "sstore for Constantinople and later",
     exec: (prep: vm2OpIgnore,
            run:  sstoreOp,
            post: vm2OpIgnore)),

    (opCode: Sstore,    ##  0x55, sstore for Istanbul and later
     forks: Vm2OpIstanbulAndLater - Vm2OpBerlinAndLater,
     name: "sstoreEIP2200",
     info: "EIP2200: sstore for Istanbul and later",
     exec: (prep: vm2OpIgnore,
            run:  sstoreEIP2200Op,
            post: vm2OpIgnore)),

    (opCode: Sstore,    ##  0x55, sstore for Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "sstoreEIP2929",
     info: "EIP2929: sstore for Istanbul and later",
     exec: (prep: vm2OpIgnore,
            run:  sstoreEIP2929Op,
            post: vm2OpIgnore)),

    (opCode: Jump,      ## 0x56, Jump
     forks: Vm2OpAllForks,
     name: "jump",
     info: "Alter the program counter",
     exec: (prep: vm2OpIgnore,
            run:  jumpOp,
            post: vm2OpIgnore)),

    (opCode: JumpI,     ## 0x57, Conditional jump
     forks: Vm2OpAllForks,
     name: "jumpI",
     info: "Conditionally alter the program counter",
     exec: (prep: vm2OpIgnore,
            run:  jumpIOp,
            post: vm2OpIgnore)),

    (opCode: Pc,        ## 0x58, Program counter prior to instruction
     forks: Vm2OpAllForks,
     name: "pc",
     info: "Get the value of the program counter prior to the increment "&
           "corresponding to this instruction",
     exec: (prep: vm2OpIgnore,
            run:  pcOp,
            post: vm2OpIgnore)),

    (opCode: Msize,     ## 0x59, Memory size
     forks: Vm2OpAllForks,
     name: "msize",
     info: "Get the size of active memory in bytes",
     exec: (prep: vm2OpIgnore,
            run:  msizeOp,
            post: vm2OpIgnore)),

    (opCode: Gas,       ##  0x5a, Get available gas
     forks: Vm2OpAllForks,
     name: "gas",
     info: "Get the amount of available gas, including the corresponding "&
           "reduction for the cost of this instruction",
     exec: (prep: vm2OpIgnore,
            run:  gasOp,
            post: vm2OpIgnore)),

    (opCode: JumpDest,  ## 0x5b, Mark jump target. This operation has no effect
                        ##       on machine state during execution
     forks: Vm2OpAllForks,
     name: "jumpDest",
     info: "Mark a valid destination for jumps",
     exec: (prep: vm2OpIgnore,
            run:  jumpDestOp,
            post: vm2OpIgnore)),

    (opCode: Tload,     ## 0x5c, Load word from transient storage.
     forks: Vm2OpCancunAndLater,
     name: "tLoad",
     info: "Load word from transient storage",
     exec: (prep: vm2OpIgnore,
            run:  tloadOp,
            post: vm2OpIgnore)),

    (opCode: Tstore,     ## 0x5d, Save word to transient storage.
     forks: Vm2OpCancunAndLater,
     name: "tStore",
     info: "Save word to transient storage",
     exec: (prep: vm2OpIgnore,
            run:  tstoreOp,
            post: vm2OpIgnore)),

    (opCode: Mcopy,     ## 0x5e, Copy memory
     forks: Vm2OpCancunAndLater,
     name: "MCopy",
     info: "Copy memory",
     exec: (prep: vm2OpIgnore,
            run:  mCopyOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
