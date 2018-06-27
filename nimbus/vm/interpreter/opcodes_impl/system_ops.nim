# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  ./call, ./impl_std_import,
  byteutils, eth_common

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

type
  Create* = ref object of Opcode

  CreateEIP150* = ref object of Create # TODO: Refactoring - put that in VM forks

  CreateByzantium* = ref object of CreateEIP150 # TODO: Refactoring - put that in VM forks

# method maxChildGasModifier(create: Create, gas: GasInt): GasInt {.base.} =
#   gas

method runLogic*(create: Create, computation) =
  # computation.gasMeter.consumeGas(computation.gasCosts[create.gasCost(computation)], reason = $create.kind) # TODO: Refactoring create gas costs
  let (value, startPosition, size) = computation.stack.popInt(3)
  let (pos, len) = (startPosition.toInt, size.toInt)
  computation.memory.extend(pos, len)

  # TODO: with ZZZZ
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #          insufficient_funds = state_db.get_balance(
  #              computation.msg.storage_address) < value
  #      stack_too_deep = computation.msg.depth + 1 > constants.STACK_DEPTH_LIMIT

  #      if insufficient_funds or stack_too_deep:
  #          computation.stack.push(0)
  #          return

  let callData = computation.memory.read(pos, len)
  # TODO refactor gas
  # let createMsgGas = create.maxChildGasModifier(computation.gasMeter.gasRemaining)
  # computation.gasMeter.consumeGas(createMsgGas, reason="CREATE")

  # TODO: with
        # with computation.vm_state.state_db() as state_db:
        #     creation_nonce = state_db.get_nonce(computation.msg.storage_address)
        #     state_db.increment_nonce(computation.msg.storage_address)

        #     contract_address = generate_contract_address(
        #         computation.msg.storage_address,
        #         creation_nonce,
        #     )

        #     is_collision = state_db.account_has_code_or_nonce(contract_address)
  let contractAddress = ZERO_ADDRESS
  let isCollision = false

  if isCollision:
    computation.vmState.logger.debug(&"Address collision while creating contract: {contractAddress.toHex}")
    computation.stack.push(0.u256)
    return

  let childMsg = computation.prepareChildMessage(
    gas=0, # TODO refactor gas
    to=CREATE_CONTRACT_ADDRESS,
    value=value,
    data=cast[seq[byte]](@[]),
    code=callData.toString,
    options=MessageOptions(createAddress: contractAddress))

  # let childComputation = computation.applyChildComputation(childMsg)
  var childComputation: BaseComputation

  if childComputation.isError:
    computation.stack.push(0.u256)
  else:
    computation.stack.push(contractAddress)
  computation.gasMeter.returnGas(childComputation.gasMeter.gasRemaining)

# TODO refactor gas
# method maxChildGasModifier(create: CreateEIP150, gas: GasInt): GasInt =
#   maxChildGasEIP150(gas)

method runLogic*(create: CreateByzantium, computation) =
  if computation.msg.isStatic:
    raise newException(WriteProtection, "Cannot modify state while inside of a STATICCALL context")
  procCall runLogic(create, computation)

proc selfdestructEIP150(computation) =
  let beneficiary = stack.popAddress()
  # TODO: with ZZZZ
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #       if not state_db.account_exists(beneficiary):
  #           computation.gas_meter.consume_gas(
  #               constants.GAS_SELFDESTRUCT_NEWACCOUNT,
  #               reason=mnemonics.SELFDESTRUCT,
  #           )
  #   _selfdestruct(computation, beneficiary)

proc selfdestructEIP161(computation) =
  let beneficiary = stack.popAddress()
  # TODO: with ZZZZ
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

proc selfdestruct(computation; beneficiary: EthAddress) =
  discard # TODO: with ZZZZ
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
  let (pos, len) = (startPosition.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Return].m_handler(computation.memory.len, pos, len),
    reason = "RETURN"
    )

  computation.memory.extend(pos, len)
  let output = memory.read(pos, len)
  computation.output = output.toString
  raise newException(Halt, "RETURN")

proc revert*(computation) =
  let (startPosition, size) = stack.popInt(2)
  let (pos, len) = (startPosition.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Op.Revert].m_handler(computation.memory.len, pos, len),
    reason = "REVERT"
    )

  computation.memory.extend(pos, len)
  let output = memory.read(pos, len).toString
  computation.output = output
  raise newException(Revert, $output)

proc selfdestruct*(computation) =
  let beneficiary = stack.popAddress()
  selfdestruct(computation, beneficiary)
  raise newException(Halt, "SELFDESTRUCT")

