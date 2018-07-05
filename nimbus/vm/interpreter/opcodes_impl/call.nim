# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, eth_common,
  # ./impl_std_import # Cannot do that due to recursive dependencies
  # .../vm/interpreter/opcodes_impl/impl_std_import.nim imports .../vm/computation.nim
  # .../vm/computation.nim                              imports .../vm/interpreter/opcodes_impl/call.nim
  # .../vm/interpreter/opcodes_impl/call.nim            imports .../vm/interpreter/opcodes_impl/impl_std_import.nim
  ../../../constants, ../../../vm_types, ../../../errors, ../../../logging,
  ../../../utils/bytes,
  ../../computation, ../../stack, ../../memory, ../../message,
  ../opcode_values, ../gas_meter, ../gas_costs

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

method callParams*(call: BaseCall, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) {.base.} =
  raise newException(NotImplementedError, "Must be implemented subclasses")

method runLogic*(call: BaseCall, computation) =
  let (gas, value, to, sender,
       codeAddress,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize,
       shouldTransferValue,
       isStatic) = call.callParams(computation)

  let (memInPos, memInLen, memOutPos, memOutLen) = (memoryInputStartPosition.toInt, memoryInputSize.toInt, memoryOutputStartPosition.toInt, memoryOutputSize.toInt)

  let (gasCost, childMsgGas) = computation.gasCosts[Op.Call].c_handler(
    value,
    GasParams() # TODO - stub
  )

  computation.memory.extend(memInPos, memInLen)
  computation.memory.extend(memOutPos, memOutLen)

  let callData = computation.memory.read(memInPos, memInLen)

  # TODO: Pre-call checks
  # with computation.vm_state.state_db(read_only=True) as state_db:
  # sender_balance = state_db.get_balance(computation.msg.storage_address)
  let senderBalance = 0.u256

  let insufficientFunds = shouldTransferValue and senderBalance < value
  let stackTooDeep = computation.msg.depth + 1 > STACK_DEPTH_LIMIT

  if insufficientFunds or stackTooDeep:
    computation.returnData = ""
    var errMessage: string
    if insufficientFunds:
      errMessage = &"Insufficient Funds: have: {senderBalance} | need: {value}"
    elif stackTooDeep:
      errMessage = "Stack Limit Reached"
    else:
      raise newException(VMError, "Invariant: Unreachable code path")

    computation.logger.debug(&"{call.kind} failure: {errMessage}")
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
    if sender != ZERO_ADDRESS:
      childMsg.sender = sender
    # let childComputation = computation.applyChildComputation(childMsg)
    # TODO
    var childComputation: BaseComputation
    if childComputation.isError:
      computation.stack.push(0.u256)
    else:
      computation.stack.push(1.u256)
    if not childComputation.shouldEraseReturnData:
      let actualOutputSize = min(memOutLen, childComputation.output.len)
      computation.memory.write(
        memOutPos,
        childComputation.output.toBytes[0 ..< actualOutputSize])
      if not childComputation.shouldBurnGas:
        computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

method callParams(call: CallCode, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = computation.stack.popAddress()

  let (value,
       memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(5)

  result = (gas,
   value,
   to,
   ZERO_ADDRESS,  # sender
   ZERO_ADDRESS,  # code_address
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   true,  # should_transfer_value,
   computation.msg.isStatic)

method callParams(call: Call, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

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

method callParams(call: DelegateCall, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let codeAddress = computation.stack.popAddress()

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

method callParams(call: StaticCall, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  let gas = computation.stack.popInt()
  let to = computation.stack.popAddress()

  let (memoryInputStartPosition, memoryInputSize,
       memoryOutputStartPosition, memoryOutputSize) = computation.stack.popInt(4)

  result = (gas,
   0.u256, # value
   to,
   ZERO_ADDRESS, # sender
   ZERO_ADDRESS, # codeAddress
   memoryInputStartPosition,
   memoryInputSize,
   memoryOutputStartPosition,
   memoryOutputSize,
   false,  # should_transfer_value,
   true) # is_static

method callParams(call: CallByzantium, computation): (UInt256, UInt256, EthAddress, EthAddress, EthAddress, UInt256, UInt256, UInt256, UInt256, bool, bool) =
  result = procCall callParams(call, computation)
  if computation.msg.isStatic and result[1] != 0:
    raise newException(WriteProtection, "Cannot modify state while inside of a STATICCALL context")
