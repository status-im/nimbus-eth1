# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  ./oph_helpers,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../db/accounts_cache,
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

  type
    GasResult = tuple[gasCost, gasRefund: GasInt]
  const
    ColdAccountAccessCost = 42

  # copied from stack.nim
  macro genTupleType(len: static[int], elemType: untyped): untyped =
    result = nnkTupleConstr.newNimNode()
    for i in 0 ..< len: result.add(elemType)

  # function stubs from stack.nim (to satisfy compiler logic)
  proc popAddress(x: var Stack): EthAddress = result
  proc popInt(x: var Stack, n: static[int]): auto =
    var rc: genTupleType(n, UInt256)
    return rc

  # function stubs from compu_helper.nim (to satisfy compiler logic)
  proc gasCosts(c: Computation): array[Op,int] = result
  proc setError(c: Computation, msg: string, burnsGas = false) = discard
  proc selfDestruct(c: Computation, address: EthAddress) = discard
  proc accountExists(c: Computation, address: EthAddress): bool = result
  proc getBalance[T](c: Computation, address: T): Uint256 = result

  # function stubs from v2utils_numeric.nim
  func cleanMemRef(x: UInt256): int = result

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = result
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard
  proc read(mem: var Memory, startPos: Natural, size: Natural): seq[byte] = @[]

  # function stubs from v2state.nim
  template mutateStateDB(vmState: BaseVMState, body: untyped) =
    block:
      var db {.inject.} = vmState.accountDb
      body

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard

  # stubs from gas_costs.nim
  type GasParams = object
    case kind*: Op
    of SelfDestruct:
      sd_condition: bool
    else:
      discard
  proc c_handler(x: int; y: Uint256, z: GasParams): GasResult = result
  proc m_handler(x: int; curMemSize, memOffset, memLen: int64): int = result

  # function stubs from accounts_cache.nim:
  func inAccessList[A,B](ac: A; address: B): bool = result
  proc accessList[A,B](ac: var A; address: B) = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

const
  returnOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf3, Halt execution returning output data.
    let (startPos, size) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[Return].m_handler(k.cpt.memory.len, pos, len),
      reason = "RETURN")
    k.cpt.memory.extend(pos, len)
    k.cpt.output = k.cpt.memory.read(pos, len)


  revertOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xfd, Halt execution reverting state changes but returning data
    ##       and remaining gas.
    let (startPos, size) = k.cpt.stack.popInt(2)

    let (pos, len) = (startPos.cleanMemRef, size.cleanMemRef)
    k.cpt.gasMeter.consumeGas(
      k.cpt.gasCosts[Revert].m_handler(k.cpt.memory.len, pos, len),
      reason = "REVERT")

    k.cpt.memory.extend(pos, len)
    k.cpt.output = k.cpt.memory.read(pos, len)
    # setError(msg, false) will signal cheap revert
    k.cpt.setError("REVERT opcode executed", false)


  invalidOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    raise newException(InvalidInstruction,
                       "Invalid instruction, received an opcode " &
                         "not implemented in the current fork.")

  # -----------
      
  selfDestructOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xff, Halt execution and register account for later deletion.
    let beneficiary = k.cpt.stack.popAddress()
    k.cpt.selfDestruct(beneficiary)

  
  selfDestructEIP150Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## selfDestructEip150 (auto generated comment)
    let beneficiary = k.cpt.stack.popAddress()

    let gasParams = GasParams(
      kind: SelfDestruct,
      sd_condition: not k.cpt.accountExists(beneficiary))
    
    let gasCost =
      k.cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
    k.cpt.gasMeter.consumeGas(
      gasCost, reason = "SELFDESTRUCT EIP150")
    k.cpt.selfDestruct(beneficiary)


  selfDestructEip161Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## selfDestructEip161 (auto generated comment)
    checkInStaticContext(k.cpt)

    let
      beneficiary = k.cpt.stack.popAddress()
      isDead = not k.cpt.accountExists(beneficiary)
      balance = k.cpt.getBalance(k.cpt.msg.contractAddress)

    let gasParams = GasParams(
      kind: SelfDestruct,
      sd_condition: isDead and not balance.isZero)

    let gasCost =
      k.cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost
    k.cpt.gasMeter.consumeGas(
      gasCost, reason = "SELFDESTRUCT EIP161")
    k.cpt.selfDestruct(beneficiary)


  selfDestructEIP2929Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## selfDestructEIP2929 (auto generated comment)
    checkInStaticContext(k.cpt)

    let
      beneficiary = k.cpt.stack.popAddress()
      isDead = not k.cpt.accountExists(beneficiary)
      balance = k.cpt.getBalance(k.cpt.msg.contractAddress)

    let gasParams = GasParams(
      kind: SelfDestruct,
      sd_condition: isDead and not balance.isZero)

    var gasCost =
      k.cpt.gasCosts[SelfDestruct].c_handler(0.u256, gasParams).gasCost

    k.cpt.vmState.mutateStateDB:
      if not db.inAccessList(beneficiary):
        db.accessList(beneficiary)
        gasCost = gasCost + ColdAccountAccessCost

    k.cpt.gasMeter.consumeGas(
      gasCost, reason = "SELFDESTRUCT EIP161")
    k.cpt.selfDestruct(beneficiary)

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
