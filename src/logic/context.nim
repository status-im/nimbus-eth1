import
  strformat,
  ../constants, ../errors, ../utils_numeric, ../computation, ../vm_state, ../account, ../db/state_db, ../validation, 
  .. / vm / [stack, message, gas_meter, memory, code_stream], .. / utils / [address, padding, bytes], ttmath

proc balance*(computation: var BaseComputation) =
  let address = forceBytesToAddress(computation.stack.popBinary)
  var balance: Int256
  # TODO computation.vmState.stateDB(read_only=True):
  #  balance = db.getBalance(address)
  # computation.stack.push(balance)

proc origin*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.origin)

proc address*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.storageAddress)

proc caller*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.sender)


proc callValue*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.value)

proc callDataLoad*(computation: var BaseComputation) =
  # Load call data into memory
  let startPosition = computation.stack.popInt.getInt
  let value = computation.msg.data[startPosition ..< startPosition + 32].toString
  let paddedValue = padRight(value, 32, "\x00")
  let normalizedValue = paddedValue.lStrip(0.char)
  computation.stack.push(normalizedValue)


proc callDataSize*(computation: var BaseComputation) =
  let size = computation.msg.data.len
  computation.stack.push(size)

proc callDataCopy*(computation: var BaseComputation) =
  let (memStartPosition,
       calldataStartPosition,
       size) = computation.stack.popInt(3)
  computation.extendMemory(memStartPosition, size)

  let wordCount = ceil32(size) div 32
  let copyGasCost = wordCount * constants.GAS_COPY
  computation.gasMeter.consumeGas(copyGasCost, reason="CALLDATACOPY fee")
  let value = computation.msg.data[calldataStartPosition.getInt ..< (calldataStartPosition + size).getInt].toString
  let paddedValue = padRight(value, size.getInt, "\x00")
  computation.memory.write(memStartPosition, size, paddedValue)


proc codesize*(computation: var BaseComputation) =
  let size = computation.code.len.i256
  computation.stack.push(size)


proc codecopy*(computation: var BaseComputation) =
  let (memStartPosition,
       codeStartPosition,
       size) = computation.stack.popInt(3)
  computation.extendMemory(memStartPosition, size)
  let wordCount = ceil32(size) div 32
  let copyGasCost = constants.GAS_COPY * wordCount

  computation.gasMeter.consumeGas(copyGasCost, reason="CODECOPY: word gas cost")
  # TODO
  # with computation.code.seek(code_start_position):
  #   code_bytes = computation.code.read(size)
  #   padded_code_bytes = pad_right(code_bytes, size, b'\x00')
  # computation.memory.write(mem_start_position, size, padded_code_bytes)


proc gasprice*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.gasPrice)


proc extCodeSize*(computation: var BaseComputation) =
  let account = forceBytesToAddress(computation.stack.popBinary)
  # TODO
  #     with computation.vm_state.state_db(read_only=True) as state_db:
  #         code_size = len(state_db.get_code(account))

  #     computation.stack.push(code_size)

proc extCodeCopy*(computation: var BaseComputation) =
  let account = forceBytesToAddress(computation.stack.popBinary)
  let (memStartPosition, codeStartPosition, size) = computation.stack.popInt(3)
  computation.extendMemory(memStartPosition, size)
  let wordCount = ceil32(size) div 32
  let copyGasCost = constants.GAS_COPY * wordCount

  computation.gasMeter.consumeGas(copyGasCost, reason="EXTCODECOPY: word gas cost")

  # TODO:
  #     with computation.vm_state.state_db(read_only=True) as state_db:
  #         code = state_db.get_code(account)
  #     code_bytes = code[code_start_position:code_start_position + size]
  #     padded_code_bytes = pad_right(code_bytes, size, b'\x00')
  #     computation.memory.write(mem_start_position, size, padded_code_bytes)

proc returnDataSize*(computation: var BaseComputation) =
  let size = computation.returnData.len
  computation.stack.push(size)

proc returnDataCopy*(computation: var BaseComputation) =
  let (memStartPosition, returnDataStartPosition, size) = computation.stack.popInt(3)
  if returnDataStartPosition + size > computation.returnData.len:
    raise newException(OutOfBoundsRead, 
      "Return data length is not sufficient to satisfy request.  Asked \n" &
      &"for data from index {returnDataStartPosition} to {returnDataStartPosition + size}. Return data is {computation.returnData.len} in \n" &
      "length")      

  computation.extendMemory(memStartPosition, size)
  let wordCount = ceil32(size) div 32
  let copyGasCost = wordCount * constants.GAS_COPY
  computation.gasMeter.consumeGas(copyGasCost, reason="RETURNDATACOPY fee")
  let value = ($computation.returnData)[returnDataStartPosition.getInt ..< (returnDataStartPosition + size).getInt]
  computation.memory.write(memStartPosition, size, value)
