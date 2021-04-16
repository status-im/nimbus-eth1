# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Call Operations
## ====================================
##

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  chronicles,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../db/accounts_cache,
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
    MsgFlags = int
    GasResult = tuple[gasCost, gasRefund: GasInt]
  const
    evmcCall         = 42
    evmcDelegateCall = 43
    evmcCallCode     = 44
    emvcStatic       = 45
    MaxCallDepth     = 46
    ColdAccountAccessCost = 47
    WarmStorageReadCost = 48

  # function stubs from stack.nim (to satisfy compiler logic)
  proc `[]`(x: Stack, i: BackwardsIndex; T: typedesc): T = result
  proc top[T](x: Stack, value: T) = discard
  proc push[T](x: Stack; n: T) = discard
  proc popAddress(x: var Stack): EthAddress = result
  proc popInt(x: var Stack): UInt256 = result

  # function stubs from v2computation.nim (to satisfy compiler logic)
  proc gasCosts(c: Computation): array[Op,int] = result
  proc getBalance[T](c: Computation, address: T): Uint256 = result
  proc newComputation[A,B](v:A, m:B, salt = 0.u256): Computation = new result
  func shouldBurnGas(c: Computation): bool = result
  proc accountExists(c: Computation, address: EthAddress): bool = result
  proc isSuccess(c: Computation): bool = result
  proc merge(c, child: Computation) = discard
  template chainTo(c, d: Computation, e: untyped) =
    c.child = d; c.continuation = proc() = e

  # function stubs from v2utils_numeric.nim
  func calcMemSize*(offset, length: int): int = result

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = result
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard
  proc read(mem: var Memory, startPos: Natural, size: Natural): seq[byte] = @[]
  proc write(mem: var Memory, startPos: Natural, val: openarray[byte]) = discard

  # function stubs from v2state.nim
  template mutateStateDB(vmState: BaseVMState, body: untyped) =
    block:
      var db {.inject.} = vmState.accountDb
      body

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard
  proc returnGas(gasMeter: var GasMeter; amount: GasInt) = discard

  # function stubs from v2utils_numeric.nim
  func cleanMemRef(x: UInt256): int = result

  # stubs from v2gas_costs.nim
  type GasParams = object
    case kind*: Op
    of Call, CallCode, DelegateCall, StaticCall:
      c_isNewAccount: bool
      c_contractGas: Uint256
      c_gasBalance, c_currentMemSize, c_memOffset, c_memLength: int64
    else:
      discard
  proc c_handler(x: int; y: Uint256, z: GasParams): GasResult = result

  # function stubs from accounts_cache.nim:
  func inAccessList[A,B](ac: A; address: B): bool = result
  proc accessList[A,B](ac: var A; address: B) = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

type
  LocalParams = tuple
    gas:             UInt256
    value:           UInt256
    destination:     EthAddress
    sender:          EthAddress
    memInPos:        int
    memInLen:        int
    memOutPos:       int
    memOutLen:       int
    flags:           MsgFlags
    memOffset:       int
    memLength:       int
    contractAddress: EthAddress


proc updateStackAndParams(q: var LocalParams; c: Computation) =
  c.stack.push(0)

  let
    outLen = calcMemSize(q.memOutPos, q.memOutLen)
    inLen = calcMemSize(q.memInPos, q.memInLen)

  # get the bigger one
  if outLen < inLen:
    q.memOffset = q.memInPos
    q.memLength = q.memInLen
  else:
    q.memOffset = q.memOutPos
    q.memLength = q.memOutLen

  # EIP2929: This came before old gas calculator
  #           because it will affect `c.gasMeter.gasRemaining`
  #           and further `childGasLimit`
  if FkBerlin <= c.fork:
    c.vmState.mutateStateDB:
      if not db.inAccessList(q.destination):
        db.accessList(q.destination)

        # The WarmStorageReadCostEIP2929 (100) is already deducted in
        # the form of a constant `gasCall`
        c.gasMeter.consumeGas(
          ColdAccountAccessCost - WarmStorageReadCost,
          reason = "EIP2929 gasCall")


proc callParams(c: Computation): LocalParams =
  ## Helper for callOp()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.value           = c.stack.popInt()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.sender          = c.msg.contractAddress
  result.flags           = c.msg.flags
  result.contractAddress = result.destination

  result.updateStackAndParams(c)


proc callCodeParams(c: Computation): LocalParams =
  ## Helper for callCodeOp()
  result = c.callParams
  result.contractAddress = c.msg.contractAddress


proc delegateCallParams(c: Computation): LocalParams =
  ## Helper for delegateCall()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.value           = c.msg.value
  result.sender          = c.msg.sender
  result.flags           = c.msg.flags
  result.contractAddress = c.msg.contractAddress

  result.updateStackAndParams(c)


proc staticCallParams(c: Computation):  LocalParams =
  ## Helper for staticCall()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.value           = 0.u256
  result.sender          = c.msg.contractAddress
  result.flags           = emvcStatic
  result.contractAddress = result.destination

  result.updateStackAndParams(c)

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  callOp: Vm2OpFn = proc(k: Vm2Ctx) =
    ## 0xf1, Message-Call into an account

    if emvcStatic == k.cpt.msg.flags and k.cpt.stack[^3, UInt256] > 0.u256:
      raise newException(
        StaticContextError,
        "Cannot modify state while inside of a STATICCALL context")
    let
      p = k.cpt.callParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[Call].c_handler(
      p.value,
      GasParams(
        kind:             Call,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $Call)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (call)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let senderBalance = k.cpt.getBalance(p.sender)
    if senderBalance < p.value:
      debug "Insufficient funds",
        available = senderBalance,
        needed = k.cpt.msg.value
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    let msg = Message(
      kind:            evmcCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    var child = newComputation(k.cpt.vmState, msg)
    k.cpt.chainTo(child):
      if not child.shouldBurnGas:
        k.cpt.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        k.cpt.merge(child)
        k.cpt.stack.top(1)

      k.cpt.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        k.cpt.memory.write(p.memOutPos,
                           child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  callCodeOp: Vm2OpFn = proc(k: Vm2Ctx) =
    ## 0xf2, Message-call into this account with an alternative account's code.
    let
      p = k.cpt.callCodeParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[CallCode].c_handler(
      p.value,
      GasParams(
        kind:             CallCode,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $CallCode)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (callCode)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let senderBalance = k.cpt.getBalance(p.sender)
    if senderBalance < p.value:
      debug "Insufficient funds",
        available = senderBalance,
        needed = k.cpt.msg.value
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    let msg = Message(
      kind:            evmcCallCode,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    var child = newComputation(k.cpt.vmState, msg)
    k.cpt.chainTo(child):
      if not child.shouldBurnGas:
        k.cpt.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        k.cpt.merge(child)
        k.cpt.stack.top(1)

      k.cpt.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        k.cpt.memory.write(p.memOutPos,
                           child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  delegateCallOp: Vm2OpFn = proc(k: Vm2Ctx) =
    ## 0xf4, Message-call into this account with an alternative account's
    ##       code, but persisting the current values for sender and value.
    let
      p = k.cpt.delegateCallParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[DelegateCall].c_handler(
      p.value,
      GasParams(
        kind: DelegateCall,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $DelegateCall)

    k.cpt.returnData.setLen(0)
    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (delegateCall)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let msg = Message(
      kind:            evmcDelegateCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    var child = newComputation(k.cpt.vmState, msg)
    k.cpt.chainTo(child):
      if not child.shouldBurnGas:
        k.cpt.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        k.cpt.merge(child)
        k.cpt.stack.top(1)

      k.cpt.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        k.cpt.memory.write(p.memOutPos,
                           child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  staticCallOp: Vm2OpFn = proc(k: Vm2Ctx) =
    ## 0xfa, Static message-call into an account.

    let
      p = k.cpt.staticCallParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[StaticCall].c_handler(
      p.value,
      GasParams(
        kind: StaticCall,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    #
    # when opCode == StaticCall:
    #  if k.cpt.fork >= FkBerlin and destination.toInt <= MaxPrecompilesAddr:
    #    gasCost = gasCost - 660.GasInt
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $StaticCall)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (staticCall)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let msg = Message(
      kind:            evmcCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    var child = newComputation(k.cpt.vmState, msg)
    k.cpt.chainTo(child):
      if not child.shouldBurnGas:
        k.cpt.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        k.cpt.merge(child)
        k.cpt.stack.top(1)

      k.cpt.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        k.cpt.memory.write(p.memOutPos,
                           child.output.toOpenArray(0, actualOutputSize - 1))

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecCall*: seq[Vm2OpExec] = @[

    (opCode: Call,         ## 0xf1, Message-Call into an account
     forks: Vm2OpAllForks,
     info: "Message-Call into an account",
     exec: (prep: vm2OpIgnore,
            run: callOp,
            post: vm2OpIgnore)),

    (opCode: CallCode,     ## 0xf2, Message-Call with alternative code
     forks: Vm2OpAllForks,
     info: "Message-call into this account with alternative account's code",
     exec: (prep: vm2OpIgnore,
            run: callCodeOp,
            post: vm2OpIgnore)),

    (opCode: DelegateCall, ## 0xf4, CallCode with persisting sender and value
     forks: Vm2OpAllForks,
     info: "Message-call into this account with an alternative account's " &
           "code but persisting the current values for sender and value.",
     exec: (prep: vm2OpIgnore,
            run: delegateCallOp,
            post: vm2OpIgnore)),

    (opCode: StaticCall,   ## 0xfa, Static message-call into an account
     forks: Vm2OpAllForks,
     info: "Static message-call into an account",
     exec: (prep: vm2OpIgnore,
            run: staticCallOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
