# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  ./oph_helpers,
  strformat,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../db/accounts_cache,
    ../../code_stream,
    ../../compu_helper,
    ../../stack,
    ../../v2memory,
    ../../v2state,
    ../../v2types,
    ../gas_costs,
    ../gas_meter,
    ../utils/v2utils_numeric,
    eth/common

else:
  import macros

  const
    ColdSloadCost = 42
    WarmStorageReadCost = 43

  # copied from stack.nim
  macro genTupleType(len: static[int], elemType: untyped): untyped =
    result = nnkTupleConstr.newNimNode()
    for i in 0 ..< len: result.add(elemType)

  # function stubs from stack.nim (to satisfy compiler logic)
  proc push[T](x: Stack; n: T) = discard
  proc popInt(x: var Stack): UInt256 = discard
  proc popInt(x: var Stack, n: static[int]): auto =
    var rc: genTupleType(n, UInt256)
    return rc

  # function stubs from compu_helper.nim (to satisfy compiler logic)
  proc getStorage(c: Computation, slot: Uint256): Uint256 = result
  proc gasCosts(c: Computation): array[Op,int] = result

  # function stubs from v2utils_numeric.nim
  func cleanMemRef(x: UInt256): int = 0

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = 0
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard
  proc write(mem: var Memory, startPos: Natural, val: openarray[byte]) = discard
  proc read(mem: var Memory, startPos: Natural, size: Natural): seq[byte] = @[]

  # function stubs from code_stream.nim
  proc len(c: CodeStream): int = len(c.bytes)
  proc peek(c: var CodeStream): Op = Stop
  proc isValidOpcode(c: CodeStream, position: int): bool = false

  # function stubs from v2state.nim
  proc readOnlyStateDB(x: BaseVMState): ReadOnlyStateDB = result
  template mutateStateDB(vmState: BaseVMState, body: untyped) =
    block:
      var db {.inject.} = vmState.accountDb
      body

  # function stubs from gas_meter.nim
  proc refundGas(gasMeter: var GasMeter; amount: int) = discard
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard

  # stubs from gas_costs.nim
  type GasParams = object
    case kind*: Op
    of Sstore:
      s_currentValue: Uint256
      s_originalValue: Uint256
    else:
      discard
  proc c_handler(x: int; y: Uint256, z: GasParams): (int,int) = result
  proc m_handler(x: int; curMemSize, memOffset, memLen: int64): int = 0

  # function stubs from state_db.nim
  proc getCommittedStorage[A,B](x: A; y: B; z: Uint256): Uint256 = result

  # function stubs from accounts_cache.nim:
  func inAccessList[A,B](ac: A; address: B; slot: UInt256): bool = result
  proc accessList[A,B](ac: var A; address: B; slot: UInt256) = discard
  proc setStorage[A,B](ac: var A; address: B, slot, value: UInt256) = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc sstoreNetGasMeteringImpl(c: Computation; slot, newValue: Uint256) =
  let
    stateDB = c.vmState.readOnlyStateDB
    currentValue = c.getStorage(slot)

    gasParam = GasParams(
      kind: Op.Sstore,
      s_currentValue: currentValue,
      s_originalValue: stateDB.getCommittedStorage(c.msg.contractAddress, slot))

    (gasCost, gasRefund) = c.gasCosts[Sstore].c_handler(newValue, gasParam)

  c.gasMeter.consumeGas(
    gasCost, &"SSTORE EIP2200: {c.msg.contractAddress}[{slot}]" &
             &" -> {newValue} ({currentValue})")

  if gasRefund != 0:
    c.gasMeter.refundGas(gasRefund)

  c.vmState.mutateStateDB:
    db.setStorage(c.msg.contractAddress, slot, newValue)


proc jumpImpl(c: Computation; jumpTarget: UInt256) =
  if jumpTarget >= c.code.len.u256:
    raise newException(
      InvalidJumpDestination, "Invalid Jump Destination")

  let jt = jumpTarget.truncate(int)
  c.code.pc = jt

  let nextOpcode = c.code.peek
  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  # TODO: next check seems redundant
  if not c.code.isValidOpcode(jt):
    raise newException(
      InvalidInstruction, "Jump resulted in invalid instruction")

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  popOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x50, Remove item from stack.
    discard k.cpt.stack.popInt

  mloadOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x51, Load word from memory
    let (memStartPos) = k.cpt.stack.popInt(1)

    let memPos = memStartPos.cleanMemRef
    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[MLoad].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MLOAD: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.stack.push:
      k.cpt.memory.read(memPos, 32)


  mstoreOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x52, Save word to memory
    let (memStartPos, value) = k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[MStore].m_handler(k.cpt.memory.len, memPos, 32),
      reason = "MSTORE: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 32)
    k.cpt.memory.write(memPos, value.toByteArrayBE)


  mstore8Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x53, Save byte to memory
    let (memStartPos, value) = k.cpt.stack.popInt(2)

    let memPos = memStartPos.cleanMemRef
    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[MStore].m_handler(k.cpt.memory.len, memPos, 1),
      reason = "MSTORE8: GasVeryLow + memory expansion")

    k.cpt.memory.extend(memPos, 1)
    k.cpt.memory.write(memPos, [value.toByteArrayBE[31]])

  # -------

  sloadOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x54, Load word from storage.
    let (slot) = k.cpt.stack.popInt(1)
    k.cpt.stack.push:
      k.cpt.getStorage(slot)

  sloadEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x54, EIP2929: Load word from storage for Berlin and later
    let (slot) = k.cpt.stack.popInt(1)

    k.cpt.vmState.mutateStateDB:
      let gasCost = if not db.inAccessList(k.cpt.msg.contractAddress, slot):
                      db.accessList(k.cpt.msg.contractAddress, slot)
                      ColdSloadCost
                    else:
                      WarmStorageReadCost
      k.cpt.gasMeter.consumeGas(gasCost, reason = "sloadEIP2929")
    k.cpt.stack.push:
      k.cpt.getStorage(slot)

  # -------

  sstoreOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x55, Save word to storage.
    let (slot, newValue) = k.cpt.stack.popInt(2)

    checkInStaticContext(k.cpt)
    # sstoreImpl(k.cpt, slot, newValue)
    # template sstoreImpl(c: Computation, slot, newValue: Uint256) =
    let
      currentValue = k.cpt.getStorage(slot)
      gasParam = GasParams(
        kind: Op.Sstore,
        s_currentValue: currentValue)

      (gasCost, gasRefund) =
        k.cpt.gasCosts[Sstore].c_handler(newValue, gasParam)

    k.cpt.gasMeter.consumeGas(
      gasCost, &"SSTORE: {k.cpt.msg.contractAddress}[{slot}] " &
               &"-> {newValue} ({currentValue})")
    if gasRefund > 0:
      k.cpt.gasMeter.refundGas(gasRefund)

    k.cpt.vmState.mutateStateDB:
      db.setStorage(k.cpt.msg.contractAddress, slot, newValue)


  sstoreEIP1283Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x55, EIP1283: sstore for Constantinople and later
    let (slot, newValue) = k.cpt.stack.popInt(2)

    checkInStaticContext(k.cpt)
    sstoreNetGasMeteringImpl(k.cpt, slot, newValue)


  sstoreEIP2200Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x55, EIP2200: sstore for Istanbul and later
    let (slot, newValue) = k.cpt.stack.popInt(2)

    checkInStaticContext(k.cpt)
    const SentryGasEIP2200 = 2300

    if k.cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
      raise newException(
        OutOfGas,
        "Gas not enough to perform EIP2200 SSTORE")

    sstoreNetGasMeteringImpl(k.cpt, slot, newValue)


  sstoreEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x55, EIP2929: sstore for Berlin and later
    let (slot, newValue) = k.cpt.stack.popInt(2)
    checkInStaticContext(k.cpt)

    # Minimum gas required to be present for an SSTORE call, not consumed
    const SentryGasEIP2200 = 2300

    if k.cpt.gasMeter.gasRemaining <= SentryGasEIP2200:
      raise newException(OutOfGas, "Gas not enough to perform EIP2200 SSTORE")

    k.cpt.vmState.mutateStateDB:
      if not db.inAccessList(k.cpt.msg.contractAddress, slot):
        db.accessList(k.cpt.msg.contractAddress, slot)
        k.cpt.gasMeter.consumeGas(ColdSloadCost, reason = "sstoreEIP2929")

    sstoreNetGasMeteringImpl(k.cpt, slot, newValue)

  # -------

  jumpOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x56, Alter the program counter
    let (jumpTarget) = k.cpt.stack.popInt(1)
    jumpImpl(k.cpt, jumpTarget)

  jumpIOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x57, Conditionally alter the program counter.
    let (jumpTarget, testedValue) = k.cpt.stack.popInt(2)
    if testedValue != 0:
      jumpImpl(k.cpt, jumpTarget)

  pcOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x58, Get the value of the program counter prior to the increment
    ##       corresponding to this instruction.
    k.cpt.stack.push:
      max(k.cpt.code.pc - 1, 0)

  msizeOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x59, Get the size of active memory in bytes.
    k.cpt.stack.push:
      k.cpt.memory.len

  gasOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5a, Get the amount of available gas, including the corresponding
    ##       reduction for the cost of this instruction.
    k.cpt.stack.push:
      k.cpt.gasMeter.gasRemaining

  jumpDestOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5b, Mark a valid destination for jumps. This operation has no effect
    ##       on machine state during execution.
    discard

  beginSubOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5c, Marks the entry point to a subroutine
    raise newException(
      OutOfGas,
      "Abort: Attempt to execute BeginSub opcode")


  returnSubOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5d, Returns control to the caller of a subroutine.
    if k.cpt.returnStack.len == 0:
      raise newException(
        OutOfGas,
        "Abort: invalid returnStack during ReturnSub")
    k.cpt.code.pc = k.cpt.returnStack.pop()


  jumpSubOp: Vm2OpFn = proc (k: var Vm2Ctx) =
    ## 0x5e, Transfers control to a subroutine.
    let (jumpTarget) = k.cpt.stack.popInt(1)

    if jumpTarget >= k.cpt.code.len.u256:
      raise newException(
        InvalidJumpDestination, "JumpSub destination exceeds code len")

    let returnPC = k.cpt.code.pc
    let jt = jumpTarget.truncate(int)
    k.cpt.code.pc = jt

    let nextOpcode = k.cpt.code.peek
    if nextOpcode != BeginSub:
      raise newException(
        InvalidJumpDestination, "Invalid JumpSub destination")

    if k.cpt.returnStack.len == 1023:
      raise newException(
        FullStack, "Out of returnStack")

    k.cpt.returnStack.add returnPC
    inc k.cpt.code.pc

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

    (opCode: BeginSub,  ## 0x5c, Begin subroutine
     forks: Vm2OpBerlinAndLater,
     name: "beginSub",
     info: " Marks the entry point to a subroutine",
     exec: (prep: vm2OpIgnore,
            run:  beginSubOp,
            post: vm2OpIgnore)),

    (opCode: ReturnSub, ## 0x5d, Return
     forks: Vm2OpBerlinAndLater,
     name: "returnSub",
     info: "Returns control to the caller of a subroutine",
     exec: (prep: vm2OpIgnore,
            run:  returnSubOp,
            post: vm2OpIgnore)),

    (opCode: JumpSub,   ## 0x5e, Call subroutine
     forks: Vm2OpBerlinAndLater,
     name: "jumpSub",
     info: "Transfers control to a subroutine",
     exec: (prep: vm2OpIgnore,
            run:  jumpSubOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
