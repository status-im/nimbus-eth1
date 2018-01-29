import
  ../constants, ../utils_numeric, ../computation, ../vm_state, ../account, ../db/state_db, ../validation, 
  .. / vm / [stack, message], .. / utils / [address, padding, bytes]

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
  let value = computation.msg.data[startPosition ..< startPosition + 32].toCString
  let paddedValue = padRight(value, 32, cstring"\x00")
  let normalizedValue = paddedValue.lStrip(0.char)
  computation.stack.push(normalizedValue)


proc callDataSize*(computation: var BaseComputation) =
  let size = computation.msg.data.len
  computation.stack.push(size)

# def calldatacopy(computation):
#     (
#         mem_start_position,
#         calldata_start_position,
#         size,
#     ) = computation.stack.pop(num_items=3, type_hint=constants.UINT256)

#     computation.extend_memory(mem_start_position, size)

#     word_count = ceil32(size) // 32
#     copy_gas_cost = word_count * constants.GAS_COPY

#     computation.gas_meter.consume_gas(copy_gas_cost, reason="CALLDATACOPY fee")

#     value = computation.msg.data[calldata_start_position: calldata_start_position + size]
#     padded_value = pad_right(value, size, b'\x00')

#     computation.memory.write(mem_start_position, size, padded_value)


# def codesize(computation):
#     size = len(computation.code)
#     computation.stack.push(size)


# def codecopy(computation):
#     (
#         mem_start_position,
#         code_start_position,
#         size,
#     ) = computation.stack.pop(num_items=3, type_hint=constants.UINT256)

#     computation.extend_memory(mem_start_position, size)

#     word_count = ceil32(size) // 32
#     copy_gas_cost = constants.GAS_COPY * word_count

#     computation.gas_meter.consume_gas(
#         copy_gas_cost,
#         reason="CODECOPY: word gas cost",
#     )

#     with computation.code.seek(code_start_position):
#         code_bytes = computation.code.read(size)

#     padded_code_bytes = pad_right(code_bytes, size, b'\x00')

#     computation.memory.write(mem_start_position, size, padded_code_bytes)


# def gasprice(computation):
#     computation.stack.push(computation.msg.gas_price)


# def extcodesize(computation):
#     account = force_bytes_to_address(computation.stack.pop(type_hint=constants.BYTES))
#     with computation.vm_state.state_db(read_only=True) as state_db:
#         code_size = len(state_db.get_code(account))

#     computation.stack.push(code_size)


# def extcodecopy(computation):
#     account = force_bytes_to_address(computation.stack.pop(type_hint=constants.BYTES))
#     (
#         mem_start_position,
#         code_start_position,
#         size,
#     ) = computation.stack.pop(num_items=3, type_hint=constants.UINT256)

#     computation.extend_memory(mem_start_position, size)

#     word_count = ceil32(size) // 32
#     copy_gas_cost = constants.GAS_COPY * word_count

#     computation.gas_meter.consume_gas(
#         copy_gas_cost,
#         reason='EXTCODECOPY: word gas cost',
#     )

#     with computation.vm_state.state_db(read_only=True) as state_db:
#         code = state_db.get_code(account)
#     code_bytes = code[code_start_position:code_start_position + size]
#     padded_code_bytes = pad_right(code_bytes, size, b'\x00')

#     computation.memory.write(mem_start_position, size, padded_code_bytes)


# def returndatasize(computation):
#     size = len(computation.return_data)
#     computation.stack.push(size)


# def returndatacopy(computation):
#     (
#         mem_start_position,
#         returndata_start_position,
#         size,
#     ) = computation.stack.pop(num_items=3, type_hint=constants.UINT256)

#     if returndata_start_position + size > len(computation.return_data):
#         raise OutOfBoundsRead(
#             "Return data length is not sufficient to satisfy request.  Asked "
#             "for data from index {0} to {1}.  Return data is {2} bytes in "
#             "length.".format(
#                 returndata_start_position,
#                 returndata_start_position + size,
#                 len(computation.return_data),
#             )
#         )

#     computation.extend_memory(mem_start_position, size)

#     word_count = ceil32(size) // 32
#     copy_gas_cost = word_count * constants.GAS_COPY

#     computation.gas_meter.consume_gas(copy_gas_cost, reason="RETURNDATACOPY fee")

#     value = computation.return_data[returndata_start_position: returndata_start_position + size]

#     computation.memory.write(mem_start_position, size, value)
