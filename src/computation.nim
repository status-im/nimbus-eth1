import
  strformat, strutils, sequtils, tables, macros,
  constants, errors, utils/hexadecimal, utils_numeric, validation, vm_state, logging,
  vm / [code_stream, gas_meter, memory, message, stack]

proc memoryGasCost*(sizeInBytes: Int256): Int256 =
  var
    sizeInWords = ceil32(sizeInBytes) div 32
    linearCost = sizeInWords * GAS_MEMORY
    quadraticCost = sizeInWords ^ 2 div GAS_MEMORY_QUADRATIC_DENOMINATOR
    totalCost = linearCost + quadraticCost
  result = totalCost

type
  BaseComputation* = ref object of RootObj
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                Memory
    stack*:                 Stack
    gasMeter*:              GasMeter
    code*:                  CodeStream
    children*:              seq[BaseComputation]
    rawOutput*:             cstring
    returnData*:            cstring
    error*:                 Error
    logEntries*:            seq[(cstring, seq[Int256], cstring)]
    shouldEraseReturnData*: bool
    accountsToDelete*:      Table[cstring, cstring]
    opcodes*:               cstring
    precompiles:            cstring
    logs*:                  bool
    logger*:                Logger

  Error* = ref object
    info*:                  string
    burnsGas*:              bool
    erasesReturnData*:      bool

proc newBaseComputation*(vmState: BaseVMState, message: Message): BaseComputation =
  new(result)
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter = newGasMeter(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[cstring, cstring]()
  result.logEntries = @[]
  result.code = newCodeStream(message.code)
  result.logger = logging.getLogger("evm.vm.computation.BaseComputation")

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
    gas: Int256,
    to: cstring,
    value: Int256,
    data: cstring,
    code: cstring,
    options: MessageOptions = newMessageOptions()): Message =
  
  # ? kwargs.setdefault('sender', self.msg.storage_address)

  var childOptions = options
  childOptions.depth = c.msg.depth + 1.Int256
  result = newMessage(
    gas,
    c.msg.gasPrice,
    c.msg.origin,
    to,
    value,
    data,
    code,
    childOptions)

  #
method extendMemory*(c: var BaseComputation, startPosition: Int256, size: Int256) =
  # Memory Management
  #
  # validate_uint256(start_position, title="Memory start position")
  # validate_uint256(size, title="Memory size")

  let beforeSize = ceil32(len(c.memory).Int256)
  let afterSize = ceil32(startPosition + size)

  let beforeCost = memoryGasCost(beforeSize)
  let afterCost = memoryGasCost(afterSize)

  c.logger.debug(%"MEMORY: size ({beforeSize} -> {afterSize}) | cost ({beforeCost} -> {afterCost})")

  if size > 0:
    if beforeCost < afterCost:
      var gasFee = afterCost - beforeCost
      c.gasMeter.consumeGas(
        gasFee,
        reason = %"Expanding memory {beforeSize} -> {afterSize}")

      c.memory.extend(startPosition, size)

method output*(c: BaseComputation): cstring =
  if c.shouldEraseReturnData:
    cstring""
  else:
    c.rawOutput

method `output=`*(c: var BaseComputation, value: cstring) =
  c.rawOutput = value

macro generateChildBaseComputation*(t: typed, vmState: typed, childMsg: typed): untyped =
  var typ = repr(getType(t)[1]).split(":", 1)[0]
  var name = ident(%"new{typ}")
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
      c.returnData = cstring""
    else:
      c.returnData = childBaseComputation.output
  else:
    if childBaseComputation.msg.isCreate:
      c.returnData = cstring""
    else:
      c.returnData = childBaseComputation.output
      c.children.add(childBaseComputation)

method applyChildBaseComputation*(c: var BaseComputation, childMsg: Message): BaseComputation =
  var childBaseComputation = generateChildBaseComputation(c, c.vmState, childMsg)
  c.addChildBaseComputation(childBaseComputation)
  result = childBaseComputation

method registerAccountForDeletion*(c: var BaseComputation, beneficiary: cstring) =
  validateCanonicalAddress(beneficiary, title="self destruct beneficiary address")

  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

method addLogEntry*(c: var BaseComputation, account: cstring, topics: seq[Int256], data: cstring) =
  validateCanonicalAddress(account, title="log entry address")
  c.logEntries.add((account, topics, data))

method getAccountsForDeletion*(c: BaseComputation): seq[(cstring, cstring)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]

method getLogEntries*(c: BaseComputation): seq[(cstring, seq[Int256], cstring)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]
      
method getGasRefund*(c: BaseComputation): Int256 =
  if c.isError:
    result = 0.Int256
  else:
    result = c.gasMeter.gasRefunded + c.children.mapIt(it.getGasRefund()).foldl(a + b, 0.Int256)

method getGasUsed*(c: BaseComputation): Int256 =
  if c.shouldBurnGas:
    result = c.msg.gas
  else:
    result = max(0.Int256, c.msg.gas - c.gasMeter.gasRemaining)

method getGasRemaining*(c: BaseComputation): Int256 =
  if c.shouldBurnGas:
    result = 0.Int256
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
        $c.msg.gasRemaining])
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

macro applyComputation(t: typed, vmState: untyped, message: untyped): untyped =
  #     Perform the computation that would be triggered by the VM message
  var typ = repr(getType(t)[1]).split(":", 1)[0]
  var name = ident(%"new{typ}")
  var typName = ident(typ)
  result = quote:
    block:
      var res: `typName`
      var c = `name`(`vmState`, `message`)
      var handler = proc: `typName` =
        if `message`.codeAddress in c.precompiles:
          c.precompiles[`message`.codeAddress](c)
          return c

        for opcode in c.code:
          var opcodeFn = c.getOpcodeFn(c.opcodes, opcode)
          c.logger.trace(
            "OPCODE: 0x$1 ($2) | pc: $3" % [$opcode, $opcodeFn, $max(0, c.code.pc - 1)])

          #try:
            # somehow call opcodeFn(c)
          #except halt:
          #  break
        return c
      inComputation(c):
        res = handler()
      res

    # #
    # # Opcode API
    # #
    # @property
    # def precompiles(self):
    #     if self._precompiles is None:
    #         return dict()
    #     else:
    #         return self._precompiles

    # def get_opcode_fn(self, opcodes, opcode):
    #     try:
    #         return opcodes[opcode]
    #     except KeyError:
    #         return InvalidOpcode(opcode)

    # #
    # # classmethod
    # #
    # @classmethod
    # def configure(cls,
    #               name,
    #               **overrides):
    #     """
    #     Class factory method for simple inline subclassing.
    #     """
    #     for key in overrides:
    #         if not hasattr(cls, key):
    #             raise TypeError(
    #                 "The BaseComputation.configure cannot set attributes that are not "
    #                 "already present on the base class.  The attribute `{0}` was "
    #                 "not found on the base class `{1}`".format(key, cls)
    #             )
    #     return type(name, (cls,), overrides)
