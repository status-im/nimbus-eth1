# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../gas_meter,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  chronicles,
  eth/common,
  eth/common/eth_types,
  stint

when not defined(evmc_enabled):
  import
    ../../state,
    ../../../db/ledger

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

type
  LocalParams = object
    gas:             UInt256
    value:           UInt256
    codeAddress:     EthAddress
    sender:          EthAddress
    memInPos:        int
    memInLen:        int
    memOutPos:       int
    memOutLen:       int
    flags:           MsgFlags
    memOffset:       int
    memLength:       int
    contractAddress: EthAddress
    gasCallEIP2929:  GasInt


proc updateStackAndParams(q: var LocalParams; c: Computation): EvmResultVoid =
  ? c.stack.push(0)

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
    when evmc_enabled:
      if c.host.accessAccount(q.codeAddress) == EVMC_ACCESS_COLD:
        q.gasCallEIP2929 = ColdAccountAccessCost - WarmStorageReadCost
    else:
      c.vmState.mutateStateDB:
        if not db.inAccessList(q.codeAddress):
          db.accessList(q.codeAddress)

          # The WarmStorageReadCostEIP2929 (100) is already deducted in
          # the form of a constant `gasCall`
          q.gasCallEIP2929 = ColdAccountAccessCost - WarmStorageReadCost
  ok()

proc callParams(c: Computation): EvmResult[LocalParams] =
  ## Helper for callOp()
  var res = LocalParams(
    gas            : ? c.stack.popInt(),
    codeAddress    : ? c.stack.popAddress(),
    value          : ? c.stack.popInt(),
    memInPos       : ? c.stack.popMemRef(),
    memInLen       : ? c.stack.popMemRef(),
    memOutPos      : ? c.stack.popMemRef(),
    memOutLen      : ? c.stack.popMemRef(),
    sender         : c.msg.contractAddress,
    flags          : c.msg.flags,
  )

  res.contractAddress = res.codeAddress
  ? res.updateStackAndParams(c)
  ok(res)


proc callCodeParams(c: Computation): EvmResult[LocalParams] =
  ## Helper for callCodeOp()
  var res = ? c.callParams()
  res.contractAddress = c.msg.contractAddress
  ok(res)


proc delegateCallParams(c: Computation): EvmResult[LocalParams] =
  ## Helper for delegateCall()
  var res = LocalParams(
    gas            : ? c.stack.popInt(),
    codeAddress    : ? c.stack.popAddress(),
    memInPos       : ? c.stack.popMemRef(),
    memInLen       : ? c.stack.popMemRef(),
    memOutPos      : ? c.stack.popMemRef(),
    memOutLen      : ? c.stack.popMemRef(),
    value          : c.msg.value,
    sender         : c.msg.sender,
    flags          : c.msg.flags,
    contractAddress: c.msg.contractAddress,
  )
  ? res.updateStackAndParams(c)
  ok(res)


proc staticCallParams(c: Computation):  EvmResult[LocalParams] =
  ## Helper for staticCall()
  var res = LocalParams(
    gas            : ? c.stack.popInt(),
    codeAddress    : ? c.stack.popAddress(),
    memInPos       : ? c.stack.popMemRef(),
    memInLen       : ? c.stack.popMemRef(),
    memOutPos      : ? c.stack.popMemRef(),
    memOutLen      : ? c.stack.popMemRef(),
    value          : 0.u256,
    sender         : c.msg.contractAddress,
    flags          : {EVMC_STATIC},
  )

  res.contractAddress = res.codeAddress
  ? res.updateStackAndParams(c)
  ok(res)

when evmc_enabled:
  template execSubCall(c: Computation; msg: ref nimbus_message; p: LocalParams) =
    c.chainTo(msg):
      c.returnData = @(makeOpenArray(c.res.output_data, c.res.output_size.int))

      let actualOutputSize = min(p.memOutLen, c.returnData.len)
      if actualOutputSize > 0:
        ? c.memory.write(p.memOutPos,
          c.returnData.toOpenArray(0, actualOutputSize - 1))

      c.gasMeter.returnGas(c.res.gas_left)
      c.gasMeter.refundGas(c.res.gas_refund)

      if c.res.status_code == EVMC_SUCCESS:
        ? c.stack.top(1)

      if not c.res.release.isNil:
        c.res.release(c.res)
      ok()

else:
  proc execSubCall(c: Computation; childMsg: Message; memPos, memLen: int) =
    ## Call new VM -- helper for `Call`-like operations

    # need to provide explicit <c> and <child> for capturing in chainTo proc()
    # <memPos> and <memLen> are provided by value and need not be captured
    var
      child = newComputation(c.vmState, false, childMsg)

    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.gasMeter.refundGas(child.gasMeter.gasRefunded)
        ? c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(memLen, child.output.len)
      if actualOutputSize > 0:
        ? c.memory.write(memPos, child.output.toOpenArray(0, actualOutputSize - 1))
      ok()

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc callOp(k: var VmCtx): EvmResultVoid =
  ## 0xf1, Message-Call into an account
  let cpt = k.cpt

  if EVMC_STATIC in cpt.msg.flags:
      let val = ? cpt.stack[^3, UInt256]
      if val > 0.u256:
        return err(opErr(StaticContext))

  let
    p = ? cpt.callParams

  var
    (gasCost, childGasLimit) = ? cpt.gasCosts[Call].c_handler(
      p.value,
      GasParams(
        kind:           Call,
        isNewAccount:   not cpt.accountExists(p.contractAddress),
        gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
        contractGas:    p.gas,
        currentMemSize: cpt.memory.len,
        memOffset:      p.memOffset,
        memLength:      p.memLength))

  # at this point gasCost is always > 0
  gasCost += p.gasCallEIP2929
  ? cpt.opcodeGastCost(Call, gasCost, reason = $Call)

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

  when evmc_enabled:
    let
      msg = new(nimbus_message)
      c   = cpt
    msg[] = nimbus_message(
      kind        : EVMC_CALL,
      depth       : (cpt.msg.depth + 1).int32,
      gas         : childGasLimit,
      sender      : p.sender,
      recipient   : p.contractAddress,
      code_address: p.codeAddress,
      input_data  : cpt.memory.readPtr(p.memInPos),
      input_size  : p.memInLen.uint,
      value       : toEvmc(p.value),
      flags       : p.flags
    )
    c.execSubCall(msg, p)
  else:
    cpt.execSubCall(
      memPos = p.memOutPos,
      memLen = p.memOutLen,
      childMsg = Message(
        kind:            EVMC_CALL,
        depth:           cpt.msg.depth + 1,
        gas:             childGasLimit,
        sender:          p.sender,
        contractAddress: p.contractAddress,
        codeAddress:     p.codeAddress,
        value:           p.value,
        data:            @(cpt.memory.read(p.memInPos, p.memInLen)),
        flags:           p.flags))
  ok()

# ---------------------

proc callCodeOp(k: var VmCtx): EvmResultVoid =
  ## 0xf2, Message-call into this account with an alternative account's code.
  let
    cpt = k.cpt
    p = ? cpt.callCodeParams

  var
    (gasCost, childGasLimit) = ? cpt.gasCosts[CallCode].c_handler(
      p.value,
      GasParams(
        kind:           CallCode,
        isNewAccount:   not cpt.accountExists(p.contractAddress),
        gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
        contractGas:    p.gas,
        currentMemSize: cpt.memory.len,
        memOffset:      p.memOffset,
        memLength:      p.memLength))

  # at this point gasCost is always > 0
  gasCost += p.gasCallEIP2929
  ? cpt.opcodeGastCost(CallCode, gasCost, reason = $CallCode)

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

  when evmc_enabled:
    let
      msg = new(nimbus_message)
      c   = cpt
    msg[] = nimbus_message(
      kind        : EVMC_CALLCODE,
      depth       : (cpt.msg.depth + 1).int32,
      gas         : childGasLimit,
      sender      : p.sender,
      recipient   : p.contractAddress,
      code_address: p.codeAddress,
      input_data  : cpt.memory.readPtr(p.memInPos),
      input_size  : p.memInLen.uint,
      value       : toEvmc(p.value),
      flags       : p.flags
    )
    c.execSubCall(msg, p)
  else:
    cpt.execSubCall(
      memPos = p.memOutPos,
      memLen = p.memOutLen,
      childMsg = Message(
        kind:            EVMC_CALLCODE,
        depth:           cpt.msg.depth + 1,
        gas:             childGasLimit,
        sender:          p.sender,
        contractAddress: p.contractAddress,
        codeAddress:     p.codeAddress,
        value:           p.value,
        data:            @(cpt.memory.read(p.memInPos, p.memInLen)),
        flags:           p.flags))
  ok()

# ---------------------

proc delegateCallOp(k: var VmCtx): EvmResultVoid =
  ## 0xf4, Message-call into this account with an alternative account's
  ##       code, but persisting the current values for sender and value.
  let
    cpt = k.cpt
    p = ? cpt.delegateCallParams

  var
    (gasCost, childGasLimit) = ? cpt.gasCosts[DelegateCall].c_handler(
      p.value,
      GasParams(
        kind:           DelegateCall,
        isNewAccount:   not cpt.accountExists(p.contractAddress),
        gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
        contractGas:    p.gas,
        currentMemSize: cpt.memory.len,
        memOffset:      p.memOffset,
        memLength:      p.memLength))

  # at this point gasCost is always > 0
  gasCost += p.gasCallEIP2929
  ? cpt.opcodeGastCost(DelegateCall, gasCost, reason = $DelegateCall)

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

  when evmc_enabled:
    let
      msg = new(nimbus_message)
      c   = cpt
    msg[] = nimbus_message(
      kind        : EVMC_DELEGATECALL,
      depth       : (cpt.msg.depth + 1).int32,
      gas         : childGasLimit,
      sender      : p.sender,
      recipient   : p.contractAddress,
      code_address: p.codeAddress,
      input_data  : cpt.memory.readPtr(p.memInPos),
      input_size  : p.memInLen.uint,
      value       : toEvmc(p.value),
      flags       : p.flags
    )
    c.execSubCall(msg, p)
  else:
    cpt.execSubCall(
      memPos = p.memOutPos,
      memLen = p.memOutLen,
      childMsg = Message(
        kind:            EVMC_DELEGATECALL,
        depth:           cpt.msg.depth + 1,
        gas:             childGasLimit,
        sender:          p.sender,
        contractAddress: p.contractAddress,
        codeAddress:     p.codeAddress,
        value:           p.value,
        data:            @(cpt.memory.read(p.memInPos, p.memInLen)),
        flags:           p.flags))
  ok()

# ---------------------

proc staticCallOp(k: var VmCtx): EvmResultVoid =
  ## 0xfa, Static message-call into an account.

  let
    cpt = k.cpt
    p = ? cpt.staticCallParams

  var
    (gasCost, childGasLimit) = ? cpt.gasCosts[StaticCall].c_handler(
      p.value,
      GasParams(
        kind:           StaticCall,
        isNewAccount:   not cpt.accountExists(p.contractAddress),
        gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
        contractGas:    p.gas,
        currentMemSize: cpt.memory.len,
        memOffset:      p.memOffset,
        memLength:      p.memLength))

  # at this point gasCost is always > 0
  gasCost += p.gasCallEIP2929
  ? cpt.opcodeGastCost(StaticCall, gasCost, reason = $StaticCall)

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

  when evmc_enabled:
    let
      msg = new(nimbus_message)
      c   = cpt
    msg[] = nimbus_message(
      kind        : EVMC_CALL,
      depth       : (cpt.msg.depth + 1).int32,
      gas         : childGasLimit,
      sender      : p.sender,
      recipient   : p.contractAddress,
      code_address: p.codeAddress,
      input_data  : cpt.memory.readPtr(p.memInPos),
      input_size  : p.memInLen.uint,
      value       : toEvmc(p.value),
      flags       : p.flags
    )
    c.execSubCall(msg, p)
  else:
    cpt.execSubCall(
      memPos = p.memOutPos,
      memLen = p.memOutLen,
      childMsg = Message(
        kind:            EVMC_CALL,
        depth:           cpt.msg.depth + 1,
        gas:             childGasLimit,
        sender:          p.sender,
        contractAddress: p.contractAddress,
        codeAddress:     p.codeAddress,
        value:           p.value,
        data:            @(cpt.memory.read(p.memInPos, p.memInLen)),
        flags:           p.flags))
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
