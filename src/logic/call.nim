# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  ../constants, ../types, ../errors, ../computation, ../opcode, ../opcode_values, ../logging,
  .. / vm / [stack, memory, gas_meter, message],
  .. / utils / [address, bytes],
  stint

type
  # TODO most of these are for gas handling

  BaseCall* = ref object of Opcode

  Call* = ref object of BaseCall

  CallCode* = ref object of BaseCall

  DelegateCall* = ref object of BaseCall

  CallEIP150* = ref object of Call

  CallCodeEIP150* = ref object of CallCode

  DelegateCallEIP150* = ref object of DelegateCall

  CallEIP161* = ref object of CallEIP150 # TODO: Refactoring - put that in VM forks

  # Byzantium
  StaticCall* = ref object of CallEIP161 # TODO: Refactoring - put that in VM forks

  CallByzantium* = ref object of CallEIP161 # TODO: Refactoring - put that in VM forks

using
  computation: var BaseComputation

method msgExtraGas*(call: BaseCall, computation; gas: UInt256, to: string, value: UInt256): UInt256 {.base.} =
  raise newException(NotImplementedError, "Must be implemented by subclasses")

method msgGas*(call: BaseCall, computation; gas: UInt256, to: string, value: UInt256): (UInt256, UInt256) {.base.} =
  let extraGas = call.msgExtraGas(computation, gas, to, value)
  let totalFee = gas + extraGas
  let childMsgGas = gas + (if value != 0: GAS_CALL_STIPEND else: 0.u256)
  (childMsgGas, totalFee)

method callParams*(call: BaseCall, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) {.base.} =
  raise newException(NotImplementedError, "Must be implemented subclasses")

method runLogic*(call: BaseCall, computation) =
  computation.gasMeter.consumeGas(computation.gasCosts[call.gasCost(computation)], reason = $call.kind) # TODO: Refactoring call gas costs
  let (gas, value, to, sender,
       codeAddress,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize,
       shouldTransferValue,
       isStatic) = call.callParams(computation)

  computation.extendMemory(memoryInputStartPosition, memoryInputSize)
  computation.extendMemory(memoryOutputStartPosition, memoryOutputSize)

  let callData = computation.memory.read(memoryInputStartPosition, memoryInputSize)
  let (childMsgGas, childMsgGasFee) = call.msgGas(computation, gas, to, value)
  computation.gasMeter.consumeGas(childMsgGasFee, reason = $call.kind)

  # TODO: Pre-call checks
  # with computation.vm_state.state_db(read_only=True) as state_db:
  # sender_balance = state_db.get_balance(computation.msg.storage_address)
  let senderBalance = 0.u256

  let insufficientFunds = shouldTransferValue and senderBalance < value
  let stackTooDeep = computation.msg.depth + 1 > constants.STACK_DEPTH_LIMIT

  if insufficientFunds or stackTooDeep:
    computation.returnData = ""
    var errMessage: string
    if insufficientFunds:
      errMessage = &"Insufficient Funds: have: {senderBalance} | need: {value}"
    elif stackTooDeep:
      errMessage = "Stack Limit Reached"
    else:
      raise newException(VMError, "Invariant: Unreachable code path")

    call.logger.debug(&"{call.kind} failure: {errMessage}")
    computation.gasMeter.returnGas(childMsgGas)
    computation.stack.push(0.u256)
  else:
    # TODO: with
    # with computation.vm_state.state_db(read_only=True) as state_db:
    #     if code_address:
    #         code = state_db.get_code(code_address)
    #     else:
    #         code = state_db.get_code(to)
    let code = ""

    let childMsg = computation.prepareChildMessage(
      childMsgGas,
      to,
      value,
      callData,
      code,
      MessageOptions(
        shouldTransferValue: shouldTransferValue,
        isStatic: isStatic))
    if not sender.isNil:
      childMsg.sender = sender
    # let childComputation = computation.applyChildComputation(childMsg)
    # TODO
    var childComputation: BaseComputation
    if childComputation.isError:
      computation.stack.push(0.u256)
    else:
      computation.stack.push(1.u256)
    if not childComputation.shouldEraseReturnData:
      let actualOutputSize = min(memoryOutputSize, childComputation.output.len.u256)
      computation.memory.write(
        memoryOutputStartPosition,
        actualOutputSize,
        childComputation.output.toBytes[0 ..< actualOutputSize.toInt])
      if not childComputation.shouldBurnGas:
        computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

method msgExtraGas(call: Call, computation; gas: UInt256, to: string, value: UInt256): UInt256 =
  # TODO: db
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #  let accountExists = db.accountExists(to)
  let accountExists = false

  let transferGasFee = if value != 0: GAS_CALL_VALUE else: 0.u256
  let createGasFee = if not accountExists: GAS_NEW_ACCOUNT else: 0.u256
  transferGasFee + createGasFee

method callParams(call: CallCode, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = forceBytesToAddress(computation.stack.popString)

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  result = (gas,
   value,
   to,
   nil,  # sender
   nil,  # code_address
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   true,  # should_transfer_value,
   computation.msg.isStatic)

method msgExtraGas(call: CallCode, computation; gas: UInt256, to: string, value: UInt256): UInt256 =
  if value != 0: GAS_CALL_VALUE else: 0.u256

method callParams(call: Call, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = forceBytesToAddress(computation.stack.popString)

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  let to = computation.msg.storageAddress
  let sender = computation.msg.storageAddress

  result = (gas,
   value,
   to,
   sender,
   codeAddress,
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   true,  # should_transfer_value,
   computation.msg.isStatic)

method msgGas(call: DelegateCall, computation; gas: UInt256, to: string, value: UInt256): (UInt256, UInt256) =
  (gas, gas)

method msgExtraGas(call: DelegateCall, computation; gas: UInt256, to: string, value: UInt256): UInt256 =
  0.u256

method callParams(call: DelegateCall, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = forceBytesToAddress(computation.stack.popString)

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  let to = computation.msg.storageAddress
  let sender = computation.msg.storageAddress
  let value = computation.msg.value

  result = (gas,
   value,
   to,
   sender,
   codeAddress,
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   false,  # should_transfer_value,
   computation.msg.isStatic)

proc maxChildGasEIP150*(gas: UInt256): UInt256 =
  gas - gas div 64

proc computeEIP150MsgGas(computation; gas: UInt256, extraGas: UInt256, value: UInt256, name: string, callStipend: UInt256): (UInt256, UInt256) =
  if computation.gasMeter.gasRemaining < extraGas:
    raise newException(OutOfGas, &"Out of gas: Needed {extraGas} - Remaining {computation.gasMeter.gasRemaining} - Reason: {name}")
  let gas = min(gas, maxChildGasEIP150(computation.gasMeter.gasRemaining - extraGas))
  let totalFee = gas + extraGas
  let childMsgGas = gas + (if value != 0: callStipend else: 0.u256)
  (childMsgGas, totalFee)

method msgGas(call: CallEIP150, computation; gas: UInt256, to: string, value: UInt256):  (UInt256, UInt256) =
  let extraGas = call.msgExtraGas(computation, gas, to, value)
  computeEIP150MsgGas(computation, gas, extraGas, value, $call.kind, GAS_CALL_STIPEND)

method msgGas(call: CallCodeEIP150, computation; gas: UInt256, to: string, value: UInt256):  (UInt256, UInt256) =
  let extraGas = call.msgExtraGas(computation, gas, to, value)
  computeEIP150MsgGas(computation, gas, extraGas, value, $call.kind, GAS_CALL_STIPEND)

method msgGas(call: DelegateCallEIP150, computation; gas: UInt256, to: string, value: UInt256):  (UInt256, UInt256) =
  let extraGas = call.msgExtraGas(computation, gas, to, value)
  computeEIP150MsgGas(computation, gas, extraGas, value, $call.kind, 0.u256)

proc msgExtraGas*(call: CallEIP161, computation; gas: UInt256, to: string, value: UInt256): UInt256 =
  # TODO: with
  #  with computation.vm_state.state_db(read_only=True) as state_db:
  #            account_is_dead = (
  #                not state_db.account_exists(to) or
  #                state_db.account_is_empty(to))
  let accountIsDead = true

  let transferGasFee = if value != 0: GAS_CALL_VALUE else: 0.u256
  let createGasFee = if accountIsDead and value != 0: GAS_NEW_ACCOUNT else: 0.u256
  transferGasFee + createGasFee


method callParams(call: StaticCall, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = forceBytesToAddress(computation.stack.popString)

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  result = (gas,
   0.u256, # value
   to,
   nil, # sender
   nil, # codeAddress
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   false,  # should_transfer_value,
   true) # is_static


method callParams(call: CallByzantium, computation): (UInt256, UInt256, string, string, string, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  result = procCall callParams(call, computation)
  if computation.msg.isStatic and result[1] != 0:
    raise newException(WriteProtection, "Cannot modify state while inside of a STATICCALL context")
