# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Create Operations
## ======================================
##

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  ./oph_helpers,
  chronicles,
  strformat,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../constants,
    ../../stack,
    ../../v2computation,
    ../../v2memory,
    ../../v2state,
    ../../v2types,
    ../gas_meter,
    ../utils/v2utils_numeric,
    ../v2gas_costs,
    eth/common

else:
  import macros

  type
    GasResult = tuple[gasCost, gasRefund: GasInt]
  const
    evmcCreate = 42
    evmcCreate2 = 43
    MaxCallDepth = 45

  # function stubs from stack.nim (to satisfy compiler logic)
  proc top[T](x: Stack, value: T) = discard
  proc peekInt(x: Stack): UInt256 = result
  proc popInt(x: var Stack): UInt256 = result

  # function stubs from v2computation.nim (to satisfy compiler logic)
  proc gasCosts(c: Computation): array[Op,int] = result
  proc getBalance[T](c: Computation, address: T): Uint256 = result
  proc newComputation[A,B](v:A, m:B, salt = 0.u256): Computation = new result
  func shouldBurnGas(c: Computation): bool = result
  proc isSuccess(c: Computation): bool = result
  proc merge(c, child: Computation) = discard
  template chainTo(c, d: Computation, e: untyped) =
    c.child = d; c.continuation = proc() = e

  # function stubs from v2utils_numeric.nim
  func safeInt(x: Uint256): int = 0

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = 0
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard
  proc read(mem: var Memory, startPos: Natural, size: Natural): seq[byte] = @[]

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard
  proc returnGas(gasMeter: var GasMeter; amount: GasInt) = discard

  # stubs from v2gas_costs.nim
  type GasParams = object
    case kind*: Op
    of Create:
      cr_currentMemSize, cr_memOffset, cr_memLength: int64
    else:
      discard
  proc c_handler(x: int; y: Uint256, z: GasParams): GasResult = result
  proc m_handler(x: int; curMemSize, memOffset, memLen: int64): int = result

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  createOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf0, Create a new account with associated code
    checkInStaticContext(k.cpt)

    let
      endowment = k.cpt.stack.popInt()
      memPos    = k.cpt.stack.popInt().safeInt
      memLen    = k.cpt.stack.peekInt().safeInt
      salt = 0.u256

    k.cpt.stack.top(0)

    let gasParams = GasParams(
      kind:              Create,
      cr_currentMemSize: k.cpt.memory.len,
      cr_memOffset:      memPos,
      cr_memLength:      memLen)

    var gasCost = k.cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    k.cpt.gasMeter.consumeGas(
      gasCost, reason = &"CREATE: GasCreate + {memLen} * memory expansion")
    k.cpt.memory.extend(memPos, memLen)
    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maxDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      return

    if endowment != 0:
      let senderBalance = k.cpt.getBalance(k.cpt.msg.contractAddress)
      if senderBalance < endowment:
        debug "Computation Failure",
          reason = "Insufficient funds available to transfer",
          required = endowment,
          balance = senderBalance
        return

    var createMsgGas = k.cpt.gasMeter.gasRemaining
    if k.cpt.fork >= FkTangerine:
      createMsgGas -= createMsgGas div 64
    k.cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE")

    let childMsg = Message(
      kind:   evmcCreate,
      depth:  k.cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: k.cpt.msg.contractAddress,
      value:  endowment,
      data:   k.cpt.memory.read(memPos, memLen))

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, childMsg, salt)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top child.msg.contractAddress
      else:
        c.returnData = child.output

  # ---------------------

  create2Op: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf5, Behaves identically to CREATE, except using keccak256
    checkInStaticContext(k.cpt)

    let
      endowment = k.cpt.stack.popInt()
      memPos    = k.cpt.stack.popInt().safeInt
      memLen    = k.cpt.stack.popInt().safeInt
      salt      = k.cpt.stack.peekInt()

    k.cpt.stack.top(0)

    let gasParams = GasParams(
      kind:              Create,
      cr_currentMemSize: k.cpt.memory.len,
      cr_memOffset:      memPos,
      cr_memLength:      memLen)

    var gasCost = k.cpt.gasCosts[Create].c_handler(1.u256, gasParams).gasCost
    gasCost = gasCost + k.cpt.gasCosts[Create2].m_handler(0, 0, memLen)

    k.cpt.gasMeter.consumeGas(
      gasCost, reason = &"CREATE: GasCreate + {memLen} * memory expansion")
    k.cpt.memory.extend(memPos, memLen)
    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maxDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      return

    if endowment != 0:
      let senderBalance = k.cpt.getBalance(k.cpt.msg.contractAddress)
      if senderBalance < endowment:
        debug "Computation Failure",
          reason = "Insufficient funds available to transfer",
          required = endowment,
          balance = senderBalance
        return

    var createMsgGas = k.cpt.gasMeter.gasRemaining
    if k.cpt.fork >= FkTangerine:
      createMsgGas -= createMsgGas div 64
    k.cpt.gasMeter.consumeGas(createMsgGas, reason = "CREATE")

    let childMsg = Message(
      kind:   evmcCreate2,
      depth:  k.cpt.msg.depth + 1,
      gas:    createMsgGas,
      sender: k.cpt.msg.contractAddress,
      value:  endowment,
      data:   k.cpt.memory.read(memPos, memLen))

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, childMsg, salt)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top child.msg.contractAddress
      else:
        c.returnData = child.output

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecCreate*: seq[Vm2OpExec] = @[

    (opCode: Create,    ## 0xf0, Create a new account with associated code
     forks: Vm2OpAllForks,
     name: "create",
     info: "Create a new account with associated code",
     exec: (prep: vm2OpIgnore,
            run: createOp,
            post: vm2OpIgnore)),

    (opCode: Create2,   ## 0xf5, Create using keccak256
     forks: Vm2OpConstantinopleAndLater,
     name: "create2",
     info: "Behaves identically to CREATE, except using keccak256",
     exec: (prep: vm2OpIgnore,
            run: create2Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
