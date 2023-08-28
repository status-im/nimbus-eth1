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

{.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`

import
  ../../../constants,
  ../../../errors,
  ../../../common/evmforks,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../../async/operations,
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
    ../../../db/accounts_cache

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

type
  LocalParams = tuple
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


proc callParams(c: Computation): LocalParams =
  ## Helper for callOp()
  result.gas             = c.stack.popInt()
  result.codeAddress     = c.stack.popAddress()
  result.value           = c.stack.popInt()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.sender          = c.msg.contractAddress
  result.flags           = c.msg.flags
  result.contractAddress = result.codeAddress

  result.updateStackAndParams(c)


proc callCodeParams(c: Computation): LocalParams =
  ## Helper for callCodeOp()
  result = c.callParams
  result.contractAddress = c.msg.contractAddress


proc delegateCallParams(c: Computation): LocalParams =
  ## Helper for delegateCall()
  result.gas             = c.stack.popInt()
  result.codeAddress     = c.stack.popAddress()
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
  result.codeAddress     = c.stack.popAddress()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.value           = 0.u256
  result.sender          = c.msg.contractAddress
  result.flags.incl        EVMC_STATIC
  result.contractAddress = result.codeAddress

  result.updateStackAndParams(c)

when evmc_enabled:
  template execSubCall(c: Computation; msg: ref nimbus_message; p: LocalParams) =
    c.chainTo(msg):
      c.returnData = @(makeOpenArray(c.res.outputData, c.res.outputSize.int))

      let actualOutputSize = min(p.memOutLen, c.returnData.len)
      if actualOutputSize > 0:
        c.memory.write(p.memOutPos,
          c.returnData.toOpenArray(0, actualOutputSize - 1))

      c.gasMeter.returnGas(c.res.gas_left)

      if c.res.status_code == EVMC_SUCCESS:
        c.stack.top(1)

      if not c.res.release.isNil:
        c.res.release(c.res)

else:
  proc execSubCall(c: Computation; childMsg: Message; memPos, memLen: int) =
    ## Call new VM -- helper for `Call`-like operations

    # need to provide explicit <c> and <child> for capturing in chainTo proc()
    # <memPos> and <memLen> are provided by value and need not be captured
    var
      child = newComputation(c.vmState, childMsg)

    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(memLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(memPos, child.output.toOpenArray(0, actualOutputSize - 1))

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  callOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf1, Message-Call into an account
    let cpt = k.cpt

    if EVMC_STATIC in cpt.msg.flags and cpt.stack[^3, UInt256] > 0.u256:
      raise newException(
        StaticContextError,
        "Cannot modify state while inside of a STATICCALL context")

    let
      p = cpt.callParams

    cpt.asyncChainTo(ifNecessaryGetAccounts(cpt.vmState, @[p.sender])):
      cpt.asyncChainTo(ifNecessaryGetCodeForAccounts(cpt.vmState, @[p.contractAddress, p.codeAddress])):
        var (gasCost, childGasLimit) = cpt.gasCosts[Call].c_handler(
          p.value,
          GasParams(
            kind:             Call,
            c_isNewAccount:   not cpt.accountExists(p.contractAddress),
            c_gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
            c_contractGas:    p.gas,
            c_currentMemSize: cpt.memory.len,
            c_memOffset:      p.memOffset,
            c_memLength:      p.memLength))

        gasCost += p.gasCallEIP2929
        if gasCost >= 0:
          cpt.opcodeGastCost(Call, gasCost, reason = $Call)

        cpt.returnData.setLen(0)

        if cpt.msg.depth >= MaxCallDepth:
          debug "Computation Failure",
            reason = "Stack too deep",
            maximumDepth = MaxCallDepth,
            depth = cpt.msg.depth
          cpt.gasMeter.returnGas(childGasLimit)
          return

        if gasCost < 0 and childGasLimit <= 0:
          raise newException(
            OutOfGas, "Gas not enough to perform calculation (call)")

        cpt.memory.extend(p.memInPos, p.memInLen)
        cpt.memory.extend(p.memOutPos, p.memOutLen)

        let senderBalance = cpt.getBalance(p.sender)
        if senderBalance < p.value:
          cpt.gasMeter.returnGas(childGasLimit)
          return

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
              data:            cpt.memory.read(p.memInPos, p.memInLen),
              flags:           p.flags))

  # ---------------------

  callCodeOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf2, Message-call into this account with an alternative account's code.
    let
      cpt = k.cpt
      p = cpt.callCodeParams

    cpt.asyncChainTo(ifNecessaryGetAccounts(cpt.vmState, @[p.sender])):
      cpt.asyncChainTo(ifNecessaryGetCodeForAccounts(cpt.vmState, @[p.contractAddress, p.codeAddress])):
        var (gasCost, childGasLimit) = cpt.gasCosts[CallCode].c_handler(
          p.value,
          GasParams(
            kind:             CallCode,
            c_isNewAccount:   not cpt.accountExists(p.contractAddress),
            c_gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
            c_contractGas:    p.gas,
            c_currentMemSize: cpt.memory.len,
            c_memOffset:      p.memOffset,
            c_memLength:      p.memLength))

        gasCost += p.gasCallEIP2929
        if gasCost >= 0:
          cpt.opcodeGastCost(CallCode, gasCost, reason = $CallCode)

        cpt.returnData.setLen(0)

        if cpt.msg.depth >= MaxCallDepth:
          debug "Computation Failure",
            reason = "Stack too deep",
            maximumDepth = MaxCallDepth,
            depth = cpt.msg.depth
          cpt.gasMeter.returnGas(childGasLimit)
          return

        if gasCost < 0 and childGasLimit <= 0:
          raise newException(
            OutOfGas, "Gas not enough to perform calculation (callCode)")

        cpt.memory.extend(p.memInPos, p.memInLen)
        cpt.memory.extend(p.memOutPos, p.memOutLen)

        let senderBalance = cpt.getBalance(p.sender)
        if senderBalance < p.value:
          cpt.gasMeter.returnGas(childGasLimit)
          return

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
              data:            cpt.memory.read(p.memInPos, p.memInLen),
              flags:           p.flags))

  # ---------------------

  delegateCallOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf4, Message-call into this account with an alternative account's
    ##       code, but persisting the current values for sender and value.
    let
      cpt = k.cpt
      p = cpt.delegateCallParams

    cpt.asyncChainTo(ifNecessaryGetAccounts(cpt.vmState, @[p.sender])):
      cpt.asyncChainTo(ifNecessaryGetCodeForAccounts(cpt.vmState, @[p.contractAddress, p.codeAddress])):
        var (gasCost, childGasLimit) = cpt.gasCosts[DelegateCall].c_handler(
          p.value,
          GasParams(
            kind: DelegateCall,
            c_isNewAccount:   not cpt.accountExists(p.contractAddress),
            c_gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
            c_contractGas:    p.gas,
            c_currentMemSize: cpt.memory.len,
            c_memOffset:      p.memOffset,
            c_memLength:      p.memLength))

        gasCost += p.gasCallEIP2929
        if gasCost >= 0:
          cpt.opcodeGastCost(DelegateCall, gasCost, reason = $DelegateCall)

        cpt.returnData.setLen(0)
        if cpt.msg.depth >= MaxCallDepth:
          debug "Computation Failure",
            reason = "Stack too deep",
            maximumDepth = MaxCallDepth,
            depth = cpt.msg.depth
          cpt.gasMeter.returnGas(childGasLimit)
          return

        if gasCost < 0 and childGasLimit <= 0:
          raise newException(
            OutOfGas, "Gas not enough to perform calculation (delegateCall)")

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
              data:            cpt.memory.read(p.memInPos, p.memInLen),
              flags:           p.flags))

  # ---------------------

  staticCallOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xfa, Static message-call into an account.

    let
      cpt = k.cpt
      p = cpt.staticCallParams

    cpt.asyncChainTo(ifNecessaryGetAccounts(cpt.vmState, @[p.sender])):
      cpt.asyncChainTo(ifNecessaryGetCodeForAccounts(cpt.vmState, @[p.contractAddress, p.codeAddress])):
        var (gasCost, childGasLimit) = cpt.gasCosts[StaticCall].c_handler(
          p.value,
          GasParams(
            kind: StaticCall,
            c_isNewAccount:   not cpt.accountExists(p.contractAddress),
            c_gasBalance:     cpt.gasMeter.gasRemaining - p.gasCallEIP2929,
            c_contractGas:    p.gas,
            c_currentMemSize: cpt.memory.len,
            c_memOffset:      p.memOffset,
            c_memLength:      p.memLength))

        gasCost += p.gasCallEIP2929
        if gasCost >= 0:
          cpt.opcodeGastCost(StaticCall, gasCost, reason = $StaticCall)

        cpt.returnData.setLen(0)

        if cpt.msg.depth >= MaxCallDepth:
          debug "Computation Failure",
            reason = "Stack too deep",
            maximumDepth = MaxCallDepth,
            depth = cpt.msg.depth
          cpt.gasMeter.returnGas(childGasLimit)
          return

        if gasCost < 0 and childGasLimit <= 0:
          raise newException(
            OutOfGas, "Gas not enough to perform calculation (staticCall)")

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
              data:            cpt.memory.read(p.memInPos, p.memInLen),
              flags:           p.flags))

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecCall*: seq[Vm2OpExec] = @[

    (opCode: Call,         ## 0xf1, Message-Call into an account
     forks: Vm2OpAllForks,
     name: "call",
     info: "Message-Call into an account",
     exec: (prep: vm2OpIgnore,
            run: callOp,
            post: vm2OpIgnore)),

    (opCode: CallCode,     ## 0xf2, Message-Call with alternative code
     forks: Vm2OpAllForks,
     name: "callCode",
     info: "Message-call into this account with alternative account's code",
     exec: (prep: vm2OpIgnore,
            run: callCodeOp,
            post: vm2OpIgnore)),

    (opCode: DelegateCall, ## 0xf4, CallCode with persisting sender and value
     forks: Vm2OpHomesteadAndLater,
     name: "delegateCall",
     info: "Message-call into this account with an alternative account's " &
           "code but persisting the current values for sender and value.",
     exec: (prep: vm2OpIgnore,
            run: delegateCallOp,
            post: vm2OpIgnore)),

    (opCode: StaticCall,   ## 0xfa, Static message-call into an account
     forks: Vm2OpByzantiumAndLater,
     name: "staticCall",
     info: "Static message-call into an account",
     exec: (prep: vm2OpIgnore,
            run: staticCallOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
