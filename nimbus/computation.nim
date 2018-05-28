# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, tables, macros, stint, terminal, math,
  constants, errors, utils/hexadecimal, utils_numeric, validation, vm_state, logging, opcode_values, vm_types,
  vm / [code_stream, gas_meter, memory, message, stack],

  # TODO further refactoring of gas cost
  vm/forks/gas_costs,
  vm/forks/f20150730_frontier/frontier_vm_state,
  vm/forks/f20161018_tangerine_whistle/tangerine_vm_state

proc memoryGasCost*(sizeInBytes: Natural): GasInt =
  let
    sizeInWords = ceil32(sizeInBytes) div 32
    linearCost = sizeInWords * GAS_MEMORY
    quadraticCost = sizeInWords ^ 2 div GAS_MEMORY_QUADRATIC_DENOMINATOR
    totalCost = linearCost + quadraticCost
  result = totalCost

#const VARIABLE_GAS_COST_OPS* = {Op.Exp}

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
  result.accountsToDelete = initTable[string, string]()
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
  result.accountsToDelete = initTable[string, string]()
  result.logEntries = @[]
  result.code = newCodeStreamFromUnescaped(message.code) # TODO: what is the best repr
  result.rawOutput = "0x"
  result.gasCosts = TangerineGasCosts

method logger*(computation: BaseComputation): Logger =
  logging.getLogger("vm.computation.BaseComputation")

method applyMessage*(c: var BaseComputation): BaseComputation =
  # Execution of an VM message
  raise newException(ValueError, "Must be implemented by subclasses")

method applyCreateMessage(c: var BaseComputation): BaseComputation =
  # Execution of an VM message to create a new contract
  raise newException(ValueError, "Must be implemented by subclasses")

method isOriginComputation*(c: BaseComputation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.isOrigin

template isSuccess*(c: BaseComputation): bool =
  c.error.isNil

template isError*(c: BaseComputation): bool =
  not c.isSuccess

method shouldBurnGas*(c: BaseComputation): bool =
  c.isError and c.error.burnsGas

method shouldEraseReturnData*(c: BaseComputation): bool =
  c.isError and c.error.erasesReturnData

method prepareChildMessage*(
    c: var BaseComputation,
    gas: GasInt,
    to: string,
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

method extendMemory*(c: var BaseComputation, startPosition: Natural, size: Natural) =
  # Memory Management

  let beforeSize = ceil32(len(c.memory))
  let afterSize = ceil32(startPosition + size)

  let beforeCost = memoryGasCost(beforeSize)
  let afterCost = memoryGasCost(afterSize)

  c.logger.debug(&"MEMORY: size ({beforeSize} -> {afterSize}) | cost ({beforeCost} -> {afterCost})")

  if size > 0:
    if beforeCost < afterCost:
      var gasFee = afterCost - beforeCost
      c.gasMeter.consumeGas(
        gasFee,
        reason = &"Expanding memory {beforeSize} -> {afterSize}")

      c.memory.extend(startPosition, size)

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

method registerAccountForDeletion*(c: var BaseComputation, beneficiary: string) =
  validateCanonicalAddress(beneficiary, title="self destruct beneficiary address")

  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

method addLogEntry*(c: var BaseComputation, account: string, topics: seq[UInt256], data: string) =
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

#
# Context Manager API
#

template inComputation*(c: untyped, handler: untyped): untyped =
  # use similarly to the python manager
  #
  # inComputation(computation):
  #   stuff

  `c`.logger.debug(
    "COMPUTATION STARTING: gas: $1 | from: $2 | to: $3 | value: $4 | depth: $5 | static: $6" % [
      $`c`.msg.gas,
      $encodeHex(`c`.msg.sender),
      $encodeHex(`c`.msg.to),
      $`c`.msg.value,
      $`c`.msg.depth,
      if c.msg.isStatic: "y" else: "n"])
  try:
    `handler`
    c.logger.debug(
      "COMPUTATION SUCCESS: from: $1 | to: $2 | value: $3 | depth: $4 | static: $5 | gas-used: $6 | gas-remaining: $7" % [
        $encodeHex(c.msg.sender),
        $encodeHex(c.msg.to),
        $c.msg.value,
        $c.msg.depth,
        if c.msg.isStatic: "y" else: "n",
        $(c.msg.gas - c.gasMeter.gasRemaining),
        $c.gasMeter.gasRemaining])
  except VMError:
    `c`.logger.debug(
      "COMPUTATION ERROR: gas: $1 | from: $2 | to: $3 | value: $4 | depth: $5 | static: $6 | error: $7" % [
        $`c`.msg.gas,
        $encodeHex(`c`.msg.sender),
        $encodeHex(`c`.msg.to),
        $c.msg.value,
        $c.msg.depth,
        if c.msg.isStatic: "y" else: "n",
        getCurrentExceptionMsg()])
    `c`.error = Error(info: getCurrentExceptionMsg())
    if c.shouldBurnGas:
      c.gasMeter.consumeGas(
        c.gasMeter.gasRemaining,
        reason="Zeroing gas due to VM Exception: $1" % getCurrentExceptionMsg())


method getOpcodeFn*(computation: var BaseComputation, op: Op): Opcode =
  if computation.opcodes.len > 0 and computation.opcodes.hasKey(op):
    computation.opcodes[op]
  else:
    raise newException(InvalidInstruction,
      &"Invalid opcode {op}")

macro applyComputation*(t: typed, vmState: untyped, message: untyped): untyped =
  # Perform the computation that would be triggered by the VM message
  # c.applyComputation(vmState, message)
  var typ = repr(getType(t)[1]).split(":", 1)[0]
  var name = ident(&"new{typ}")
  var typName = ident(typ)
  result = quote:
    block:
      var res: `typName`
      var c = `t` # `name`(`vmState`, `message`)
      var handler = proc: `typName` =
        # TODO
        # if `message`.codeAddress in c.precompiles:
        #   c.precompiles[`message`.codeAddress].run(c)
        #   return c

        for op in c.code:
          var opcode = c.getOpcodeFn(op)
          c.logger.trace(
            "OPCODE: 0x$1 ($2) | pc: $3" % [opcode.kind.int.toHex(2), $opcode.kind, $max(0, c.code.pc - 1)])
          try:
            opcode.run(c)
          except Halt:
            break
          c.logger.log($c.stack & "\n\n", fgGreen)
        return c
      inComputation(c):
        res = handler()
      c
