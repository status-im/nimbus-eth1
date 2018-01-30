import
  ../constants, ../errors, ../computation, .. / db / state_db, .. / vm / [stack, gas_meter, message]

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc sstore*(computation) =
  let (slot, value) = stack.popInt(2)

  # TODO: stateDB
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #      current_value = state_db.get_storage(
  #          address=computation.msg.storage_address,
  #          slot=slot,
  #      )

  # let isCurrentlyEmpty = not bool(current_value)
  # let isGoingToBeEmpty = not bool(value)

  # if is_currently_empty:
  #      gas_refund = 0
  #  elif is_going_to_be_empty:
  #      gas_refund = constants.REFUND_SCLEAR
  #  else:
  #      gas_refund = 0

  #  if is_currently_empty and is_going_to_be_empty:
  #      gas_cost = constants.GAS_SRESET
  #  elif is_currently_empty:
  #      gas_cost = constants.GAS_SSET
  #  elif is_going_to_be_empty:
  #      gas_cost = constants.GAS_SRESET
  #  else:
  #      gas_cost = constants.GAS_SRESET

    # computation.gas_meter.consume_gas(gas_cost, reason="SSTORE: {0}[{1}] -> {2} ({3})".format(
    #     encode_hex(computation.msg.storage_address),
    #     slot,
    #     value,
    #     current_value,
    # ))

    # if gas_refund:
    #     computation.gas_meter.refund_gas(gas_refund)

    # with computation.vm_state.state_db() as state_db:
    #     state_db.set_storage(
    #         address=computation.msg.storage_address,
    #         slot=slot,
    #         value=value,
    #     )


proc sload*(computation) =
  let slot = stack.popInt()

  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #      value = state_db.get_storage(
  #          address=computation.msg.storage_address,
  #          slot=slot,
  #      )
  #  computation.stack.push(value)
