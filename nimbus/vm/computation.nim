# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, macros, terminal, math, tables,
  eth_common, byteutils,
  ../constants, ../errors, ../validation, ../vm_state, ../logging, ../vm_types,
  ./interpreter/[opcode_values,gas_meter, gas_costs],
  ./code_stream, ./memory, ./message, ./stack,

  # TODO further refactoring of gas cost
  ./forks/f20150730_frontier/frontier_vm_state,
  ./forks/f20161018_tangerine_whistle/tangerine_vm_state

method newBaseComputation*(vmState: BaseVMState, message: Message): BaseComputation {.base.}=
  raise newException(ValueError, "Must be implemented by subclasses")

# TODO refactor that
method newBaseComputation*(vmState: FrontierVMState, message: Message): BaseComputation =
  new(result)
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter = newGasMeter(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.logEntries = @[]
  result.code = newCodeStreamFromUnescaped(message.code) # TODO: what is the best repr
  result.rawOutput = "0x"
  result.gasCosts = BaseGasCosts

method newBaseComputation*(vmState: TangerineVMState, message: Message): BaseComputation =
  new(result)
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter = newGasMeter(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.logEntries = @[]
  result.code = newCodeStreamFromUnescaped(message.code) # TODO: what is the best repr
  result.rawOutput = "0x"
  result.gasCosts = TangerineGasCosts

proc logger*(computation: BaseComputation): Logger =
  logging.getLogger("vm.computation.BaseComputation")

method applyMessage*(c: var BaseComputation): BaseComputation =
  # Execution of an VM message
  raise newException(ValueError, "Must be implemented by subclasses")

method applyCreateMessage(c: var BaseComputation): BaseComputation =
  # Execution of an VM message to create a new contract
  raise newException(ValueError, "Must be implemented by subclasses")

proc isOriginComputation*(c: BaseComputation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.isOrigin

template isSuccess*(c: BaseComputation): bool =
  c.error.isNil

template isError*(c: BaseComputation): bool =
  not c.isSuccess

proc shouldBurnGas*(c: BaseComputation): bool =
  c.isError and c.error.burnsGas

proc shouldEraseReturnData*(c: BaseComputation): bool =
  c.isError and c.error.erasesReturnData

method prepareChildMessage*(
    c: var BaseComputation,
    gas: GasInt,
    to: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: string,
    options: MessageOptions = newMessageOptions()): Message =

  var childOptions = options
  childOptions.depth = c.msg.depth + 1
  result = newMessage(
    gas,
    c.msg.gasPrice,
    c.msg.origin,
    to,
    value,
    data,
    code,
    childOptions)

method output*(c: BaseComputation): string =
  if c.shouldEraseReturnData:
    ""
  else:
    c.rawOutput

method `output=`*(c: var BaseComputation, value: string) =
  c.rawOutput = value

macro generateChildBaseComputation*(t: typed, vmState: typed, childMsg: typed): untyped =
  var typ = repr(getType(t)[1]).split(":", 1)[0]
  var name = ident(&"new{typ}")
  var typName = ident(typ)
  result = quote:
    block:
      var c: `typName`
      if childMsg.isCreate:
        var child = `name`(`vmState`, `childMsg`)
        c = child.applyCreateMessage()
      else:
        var child = `name`(`vmState`, `childMsg`)
        c = child.applyMessage()
      c

method addChildBaseComputation*(c: var BaseComputation, childBaseComputation: BaseComputation) =
  if childBaseComputation.isError:
    if childBaseComputation.msg.isCreate:
      c.returnData = childBaseComputation.output
    elif childBaseComputation.shouldBurnGas:
      c.returnData = ""
    else:
      c.returnData = childBaseComputation.output
  else:
    if childBaseComputation.msg.isCreate:
      c.returnData = ""
    else:
      c.returnData = childBaseComputation.output
      c.children.add(childBaseComputation)

method applyChildBaseComputation*(c: var BaseComputation, childMsg: Message): BaseComputation =
  var childBaseComputation = generateChildBaseComputation(c, c.vmState, childMsg)
  c.addChildBaseComputation(childBaseComputation)
  result = childBaseComputation

method registerAccountForDeletion*(c: var BaseComputation, beneficiary: EthAddress) =
  validateCanonicalAddress(beneficiary, title="self destruct beneficiary address")

  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

method addLogEntry*(c: var BaseComputation, account: EthAddress, topics: seq[UInt256], data: string) =
  validateCanonicalAddress(account, title="log entry address")
  c.logEntries.add((account, topics, data))

# many methods are basically TODO, but they still return valid values
# in order to test some existing code
method getAccountsForDeletion*(c: BaseComputation): seq[(string, string)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]

method getLogEntries*(c: BaseComputation): seq[(string, seq[UInt256], string)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]

method getGasRefund*(c: BaseComputation): GasInt =
  if c.isError:
    result = 0
  else:
    result = c.gasMeter.gasRefunded + c.children.mapIt(it.getGasRefund()).foldl(a + b, 0'i64)

method getGasUsed*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = c.msg.gas
  else:
    result = max(0, c.msg.gas - c.gasMeter.gasRemaining)

method getGasRemaining*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = 0
  else:
    result = c.gasMeter.gasRemaining
