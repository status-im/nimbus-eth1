import
  strformat,
  ../constants, ../errors, ../computation, ../opcode, ../opcode_values, ../logging, ../vm_state, call,
  .. / vm / [stack, gas_meter, memory, message], .. / utils / [address, hexadecimal, bytes],
  ttmath

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

type
  Create* = ref object of Opcode

  CreateEIP150* = ref object of Create

  CreateByzantium* = ref object of CreateEIP150

method maxChildGasModifier(create: Create, gas: Int256): Int256 {.base.} =
  gas

method runLogic*(create: Create, computation) =
  computation.gasMeter.consumeGas(create.gasCost(computation), reason = $create.kind)
  let (value, startPosition, size) = computation.stack.popInt(3)
  computation.extendMemory(startPosition, size)

  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #          insufficient_funds = state_db.get_balance(
  #              computation.msg.storage_address) < value
  #      stack_too_deep = computation.msg.depth + 1 > constants.STACK_DEPTH_LIMIT

  #      if insufficient_funds or stack_too_deep:
  #          computation.stack.push(0)
  #          return

  let callData = computation.memory.read(startPosition, size)
  let createMsgGas = create.maxChildGasModifier(computation.gasMeter.gasRemaining)
  computation.gasMeter.consumeGas(createMsgGas, reason="CREATE")

  # TODO: with
        # with computation.vm_state.state_db() as state_db:
        #     creation_nonce = state_db.get_nonce(computation.msg.storage_address)
        #     state_db.increment_nonce(computation.msg.storage_address)

        #     contract_address = generate_contract_address(
        #         computation.msg.storage_address,
        #         creation_nonce,
        #     )

        #     is_collision = state_db.account_has_code_or_nonce(contract_address)
  let contractAddress = ""
  let isCollision = false

  if isCollision:
    computation.vmState.logger.debug(&"Address collision while creating contract: {contractAddress.encodeHex}")
    computation.stack.push(0.i256)
    return

  let childMsg = computation.prepareChildMessage(
    gas=createMsgGas,
    to=constants.CREATE_CONTRACT_ADDRESS,
    value=value,
    data=cast[seq[byte]](@[]),
    code=callData.toString,
    options=MessageOptions(createAddress: contractAddress))

  # let childComputation = computation.applyChildComputation(childMsg)
  var childComputation: BaseComputation

  if childComputation.isError:
    computation.stack.push(0.i256)
  else:
    computation.stack.push(contractAddress)
  computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

method maxChildGasModifier(create: CreateEIP150, gas: Int256): Int256 =
  maxChildGasEIP150(gas)

method runLogic*(create: CreateByzantium, computation) =
  if computation.msg.isStatic:
    raise newException(WriteProtection, "Cannot modify state while inside of a STATICCALL context")
  procCall runLogic(create, computation)

proc selfdestructEIP150(computation) =
  let beneficiary = forceBytesToAddress(stack.popBinary)
  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #       if not state_db.account_exists(beneficiary):
  #           computation.gas_meter.consume_gas(
  #               constants.GAS_SELFDESTRUCT_NEWACCOUNT,
  #               reason=mnemonics.SELFDESTRUCT,
  #           )
  #   _selfdestruct(computation, beneficiary)

proc selfdestructEIP161(computation) =
  let beneficiary = forceBytesToAddress(stack.popBinary)
  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #       is_dead = (
  #          not state_db.account_exists(beneficiary) or
  #          state_db.account_is_empty(beneficiary)
  #      )
  #      if is_dead and state_db.get_balance(computation.msg.storage_address):
  #          computation.gas_meter.consume_gas(
  #              constants.GAS_SELFDESTRUCT_NEWACCOUNT,
  #              reason=mnemonics.SELFDESTRUCT,
  #          )
  #  _selfdestruct(computation, beneficiary)

proc selfdestruct(computation; beneficiary: string) =
  discard # TODO: with
  # with computation.vm_state.state_db() as state_db:
  #     local_balance = state_db.get_balance(computation.msg.storage_address)
  #     beneficiary_balance = state_db.get_balance(beneficiary)

  #     # 1st: Transfer to beneficiary
  #     state_db.set_balance(beneficiary, local_balance + beneficiary_balance)
  #     # 2nd: Zero the balance of the address being deleted (must come after
  #     # sending to beneficiary in case the contract named itself as the
  #     # beneficiary.
  #     state_db.set_balance(computation.msg.storage_address, 0)

  # computation.vm_state.logger.debug(
  #     "SELFDESTRUCT: %s (%s) -> %s",
  #     encode_hex(computation.msg.storage_address),
  #     local_balance,
  #     encode_hex(beneficiary))

  # 3rd: Register the account to be deleted
  computation.registerAccountForDeletion(beneficiary)
  raise newException(Halt, "SELFDESTRUCT")


proc returnOp*(computation) =
  let (startPosition, size) = stack.popInt(2)
  computation.extendMemory(startPosition, size)
  let output = memory.read(startPosition, size).toString
  computation.output = output
  raise newException(Halt, "RETURN")

proc revert*(computation) =
  let (startPosition, size) = stack.popInt(2)
  computation.extendMemory(startPosition, size)
  let output = memory.read(startPosition, size).toString
  computation.output = output
  raise newException(Revert, $output)

proc selfdestruct*(computation) =
  let beneficiary = forceBytesToAddress(stack.popBinary)
  selfdestruct(computation, beneficiary)
  raise newException(Halt, "SELFDESTRUCT")

