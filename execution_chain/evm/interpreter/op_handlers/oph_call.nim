# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
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

{.push raises: [].}

import
  ../../../constants,
  ../../evm_errors,
  ../../../common/evmforks,
  ../../../core/eip7702,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../gas_meter,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  chronicles,
  eth/common/addresses,
  stew/assign2,
  stint,
  ../../state,
  ../../message,
  ../../../db/ledger

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

type
  # Implementation node: LocalParams is passed by `var` in the constructors
  # below since copying it is (measurably) slow, specially during the ~2.3M
  # block height attack
  LocalParams = object
    gas:             UInt256
    value:           UInt256
    codeAddress:     Address
    sender:          Address
    memInPos:        int
    memInLen:        int
    memOutPos:       int
    memOutLen:       int
    flags:           set[MsgFlags]
    memOffset:       int
    memLength:       int
    contractAddress: Address
    gasCallEIP2929:  proc(): GasInt {.gcsafe, raises: [].}
    gasCallDelegate: proc(): GasInt {.gcsafe, raises: [].}

proc updateStackAndParams(q: var LocalParams; c: Computation) =
  c.stack.lsTop(0)

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

  let codeAddress = q.codeAddress

  # EIP2929: This came before old gas calculator
  #           because it will affect `c.gasMeter.gasRemaining`
  #           and further `childGasLimit`
proc gasCallEIP2929(c: Computation, codeAddress: Address): GasProc =
  if FkBerlin <= c.fork:
    GasProc proc(): GasInt =
      c.vmState.mutateLedger:
        if not ledger.inAccessList(codeAddress):
          ledger.accessList(codeAddress)

          # The WarmStorageReadCostEIP2929 (100) is already deducted in
          # the form of a constant `gasCall`
          (ColdAccountAccessCost - WarmStorageReadCost).GasInt
        else:
          0.GasInt
  else:
    GasProc proc(): GasInt =
      0.GasInt

proc gasCallDelegate(c: Computation, codeAddress: Address): GasProc =
  if FkPrague <= c.fork:
    GasProc proc(): GasInt =
      let delegateTo = parseDelegationAddress(c.getCode(codeAddress)).valueOr:
        return 0.GasInt
      delegateResolutionCost(c, delegateTo)
  else:
    GasProc proc(): GasInt =
      0.GasInt


proc callParams(c: Computation, res: var LocalParams): EvmResult[void] =
  ## Helper for callOp()

  ? c.stack.lsCheck(7)

  res = LocalParams(
    gas            : c.stack.lsPeekInt(^1),
    codeAddress    : c.stack.lsPeekAddress(^2),
    value          : c.stack.lsPeekInt(^3),
    memInPos       : c.stack.lsPeekMemRef(^4),
    memInLen       : c.stack.lsPeekMemRef(^5),
    memOutPos      : c.stack.lsPeekMemRef(^6),
    memOutLen      : c.stack.lsPeekMemRef(^7),
    sender         : c.msg.contractAddress,
    flags          : c.msg.flags,
  )

  c.stack.lsShrink(6)
  res.contractAddress = res.codeAddress
  res.updateStackAndParams(c)
  ok()


proc callCodeParams(c: Computation, res: var LocalParams): EvmResult[void] =
  ## Helper for callCodeOp()
  ? c.callParams(res)
  res.contractAddress = c.msg.contractAddress
  ok()


proc delegateCallParams(c: Computation, res: var LocalParams): EvmResult[void] =
  ## Helper for delegateCall()

  ? c.stack.lsCheck(6)
  res = LocalParams(
    gas            : c.stack.lsPeekInt(^1),
    codeAddress    : c.stack.lsPeekAddress(^2),
    memInPos       : c.stack.lsPeekMemRef(^3),
    memInLen       : c.stack.lsPeekMemRef(^4),
    memOutPos      : c.stack.lsPeekMemRef(^5),
    memOutLen      : c.stack.lsPeekMemRef(^6),
    value          : c.msg.value,
    sender         : c.msg.sender,
    flags          : c.msg.flags,
    contractAddress: c.msg.contractAddress,
  )

  c.stack.lsShrink(5)
  res.updateStackAndParams(c)
  ok()


proc staticCallParams(c: Computation, res: var LocalParams): EvmResult[void] =
  ## Helper for staticCall()

  ? c.stack.lsCheck(6)
  res = LocalParams(
    gas            : c.stack.lsPeekInt(^1),
    codeAddress    : c.stack.lsPeekAddress(^2),
    memInPos       : c.stack.lsPeekMemRef(^3),
    memInLen       : c.stack.lsPeekMemRef(^4),
    memOutPos      : c.stack.lsPeekMemRef(^5),
    memOutLen      : c.stack.lsPeekMemRef(^6),
    value          : 0.u256,
    sender         : c.msg.contractAddress,
    flags          : {MsgFlags.Static},
  )

  c.stack.lsShrink(5)
  res.contractAddress = res.codeAddress
  res.updateStackAndParams(c)
  ok()

proc execSubCall(c: Computation; childMsg: Message; memPos, memLen: int) =
  ## Call new VM -- helper for `Call`-like operations

  # need to provide explicit <c> and <child> for capturing in chainTo proc()
  # <memPos> and <memLen> are provided by value and need not be captured
  var
    code = getCallCode(c.vmState, childMsg.codeAddress)
    child = newComputation(
      c.vmState, keepStack = false, childMsg, code)

  c.chainTo(child):
    if not child.shouldBurnGas:
      c.gasMeter.returnGas(child.gasMeter.gasRemaining)

    if child.isSuccess:
      c.merge(child)
      c.stack.lsTop(1)

    let actualOutputSize = min(memLen, child.output.len)
    if actualOutputSize > 0:
      ? c.memory.write(memPos, child.output.toOpenArray(0, actualOutputSize - 1))
    c.returnData = move(child.output)
    ok()

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc callOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf1, Message-Call into an account
  if MsgFlags.Static in cpt.msg.flags:
    let val = ? cpt.stack[^3, UInt256]
    if val > 0.u256:
      return err(opErr(StaticContext))

  var p: LocalParams
  ?cpt.callParams(p)

  let
    isNewAccount = proc(): bool = not cpt.accountExists(p.contractAddress)
    (gasCost, childGasLimit) = ? cpt.gasCosts[Call].c_handler(
      p.value,
      GasParams(
        kind:            Call,
        isNewAccount:    isNewAccount,
        gasLeft:         cpt.gasMeter.gasRemaining,
        gasCallEIP2929:  cpt.gasCallEIP2929(p.codeAddress),
        gasCallDelegate: cpt.gasCallDelegate(p.codeAddress),
        contractGas:     p.gas,
        currentMemSize:  cpt.memory.len,
        memOffset:       p.memOffset,
        memLength:       p.memLength))

  ? cpt.opcodeGasCost(Call, gasCost, reason = $Call)

  cpt.returnData.setLen(0)

  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maximumDepth = MaxCallDepth,
      depth = cpt.msg.depth
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  cpt.memory.extend(p.memInPos, p.memInLen)
  cpt.memory.extend(p.memOutPos, p.memOutLen)

  let senderBalance = cpt.getBalance(p.sender)
  if senderBalance < p.value:
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  var childMsg = Message(
    kind:            CallKind.Call,
    depth:           cpt.msg.depth + 1,
    gas:             childGasLimit,
    sender:          p.sender,
    contractAddress: p.contractAddress,
    codeAddress:     p.codeAddress,
    value:           p.value,
    flags:           p.flags)
  assign(childMsg.data, cpt.memory.read(p.memInPos, p.memInLen))
  cpt.execSubCall(
    memPos = p.memOutPos,
    memLen = p.memOutLen,
    childMsg = childMsg)
  ok()

# ---------------------

proc callCodeOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf2, Message-call into this account with an alternative account's code.
  var p: LocalParams
  ?cpt.callCodeParams(p)

  let
    isNewAccount = proc(): bool = not cpt.accountExists(p.contractAddress)
    (gasCost, childGasLimit) = ? cpt.gasCosts[CallCode].c_handler(
      p.value,
      GasParams(
        kind:            CallCode,
        isNewAccount:    isNewAccount,
        gasLeft:         cpt.gasMeter.gasRemaining,
        gasCallEIP2929:  cpt.gasCallEIP2929(p.codeAddress),
        gasCallDelegate: cpt.gasCallDelegate(p.codeAddress),
        contractGas:     p.gas,
        currentMemSize:  cpt.memory.len,
        memOffset:       p.memOffset,
        memLength:       p.memLength))

  ? cpt.opcodeGasCost(CallCode, gasCost, reason = $CallCode)

  cpt.returnData.setLen(0)

  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maximumDepth = MaxCallDepth,
      depth = cpt.msg.depth
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  cpt.memory.extend(p.memInPos, p.memInLen)
  cpt.memory.extend(p.memOutPos, p.memOutLen)

  let senderBalance = cpt.getBalance(p.sender)
  if senderBalance < p.value:
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  var childMsg = Message(
    kind:            CallKind.CallCode,
    depth:           cpt.msg.depth + 1,
    gas:             childGasLimit,
    sender:          p.sender,
    contractAddress: p.contractAddress,
    codeAddress:     p.codeAddress,
    value:           p.value,
    flags:           p.flags)
  assign(childMsg.data, cpt.memory.read(p.memInPos, p.memInLen))
  cpt.execSubCall(
    memPos = p.memOutPos,
    memLen = p.memOutLen,
    childMsg = childMsg)
  ok()

# ---------------------

proc delegateCallOp(cpt: VmCpt): EvmResultVoid =
  ## 0xf4, Message-call into this account with an alternative account's
  ##       code, but persisting the current values for sender and value.
  var p: LocalParams
  ? cpt.delegateCallParams(p)
  let
    isNewAccount = proc(): bool = not cpt.accountExists(p.contractAddress)
    (gasCost, childGasLimit) = ? cpt.gasCosts[DelegateCall].c_handler(
      p.value,
      GasParams(
        kind:            DelegateCall,
        isNewAccount:    isNewAccount,
        gasLeft:         cpt.gasMeter.gasRemaining,
        gasCallEIP2929:  cpt.gasCallEIP2929(p.codeAddress),
        gasCallDelegate: cpt.gasCallDelegate(p.codeAddress),
        contractGas:     p.gas,
        currentMemSize:  cpt.memory.len,
        memOffset:       p.memOffset,
        memLength:       p.memLength))

  ? cpt.opcodeGasCost(DelegateCall, gasCost, reason = $DelegateCall)

  cpt.returnData.setLen(0)
  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maximumDepth = MaxCallDepth,
      depth = cpt.msg.depth
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  cpt.memory.extend(p.memInPos, p.memInLen)
  cpt.memory.extend(p.memOutPos, p.memOutLen)

  var childMsg = Message(
    kind:            CallKind.DelegateCall,
    depth:           cpt.msg.depth + 1,
    gas:             childGasLimit,
    sender:          p.sender,
    contractAddress: p.contractAddress,
    codeAddress:     p.codeAddress,
    value:           p.value,
    flags:           p.flags)
  assign(childMsg.data, cpt.memory.read(p.memInPos, p.memInLen))
  cpt.execSubCall(
    memPos = p.memOutPos,
    memLen = p.memOutLen,
    childMsg = childMsg)
  ok()

# ---------------------

proc staticCallOp(cpt: VmCpt): EvmResultVoid =
  ## 0xfa, Static message-call into an account.
  var p: LocalParams
  ?cpt.staticCallParams(p)
  let
    isNewAccount = proc(): bool = not cpt.accountExists(p.contractAddress)
    (gasCost, childGasLimit) = ? cpt.gasCosts[StaticCall].c_handler(
      p.value,
      GasParams(
        kind:            StaticCall,
        isNewAccount:    isNewAccount,
        gasLeft:         cpt.gasMeter.gasRemaining,
        gasCallEIP2929:  cpt.gasCallEIP2929(p.codeAddress),
        gasCallDelegate: cpt.gasCallDelegate(p.codeAddress),
        contractGas:     p.gas,
        currentMemSize:  cpt.memory.len,
        memOffset:       p.memOffset,
        memLength:       p.memLength))

  ? cpt.opcodeGasCost(StaticCall, gasCost, reason = $StaticCall)

  cpt.returnData.setLen(0)

  if cpt.msg.depth >= MaxCallDepth:
    debug "Computation Failure",
      reason = "Stack too deep",
      maximumDepth = MaxCallDepth,
      depth = cpt.msg.depth
    cpt.gasMeter.returnGas(childGasLimit)
    return ok()

  cpt.memory.extend(p.memInPos, p.memInLen)
  cpt.memory.extend(p.memOutPos, p.memOutLen)

  var childMsg = Message(
    kind:            CallKind.Call,
    depth:           cpt.msg.depth + 1,
    gas:             childGasLimit,
    sender:          p.sender,
    contractAddress: p.contractAddress,
    codeAddress:     p.codeAddress,
    value:           p.value,
    flags:           p.flags)
  assign(childMsg.data, cpt.memory.read(p.memInPos, p.memInLen))
  cpt.execSubCall(
    memPos = p.memOutPos,
    memLen = p.memOutLen,
    childMsg = childMsg)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecCall*: seq[VmOpExec] = @[

    (opCode: Call,         ## 0xf1, Message-Call into an account
     forks: VmOpAllForks,
     name: "call",
     info: "Message-Call into an account",
     exec: callOp),


    (opCode: CallCode,     ## 0xf2, Message-Call with alternative code
     forks: VmOpAllForks,
     name: "callCode",
     info: "Message-call into this account with alternative account's code",
     exec: callCodeOp),


    (opCode: DelegateCall, ## 0xf4, CallCode with persisting sender and value
     forks: VmOpHomesteadAndLater,
     name: "delegateCall",
     info: "Message-call into this account with an alternative account's " &
           "code but persisting the current values for sender and value.",
     exec: delegateCallOp),


    (opCode: StaticCall,   ## 0xfa, Static message-call into an account
     forks: VmOpByzantiumAndLater,
     name: "staticCall",
     info: "Static message-call into an account",
     exec: staticCallOp)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
