import
  ../constants, ../errors, ../computation, ../vm_state, .. / db / [db_chain, state_db], .. / vm / [stack, gas_meter, message], strformat, ttmath, utils / header

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc sstore*(computation) =
  let (slot, value) = stack.popInt(2)

  var currentValue = 0.u256
  var existing = false

  computation.vmState.db(readOnly=false):
    (currentValue, existing) = db.getStorage(computation.msg.storageAddress, slot)

  let isCurrentlyEmpty = not existing # currentValue == 0
  let isGoingToBeEmpty = value == 0

  let gasRefund = if isCurrentlyEmpty or not isGoingToBeEmpty: 0.u256 else: REFUND_SCLEAR
  let gasCost = if isCurrentlyEmpty and not isGoingToBeEmpty: GAS_SSET else: GAS_SRESET

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.storageAddress}[slot] -> {value} ({currentValue})")
  
  if gasRefund > 0: computation.gasMeter.refundGas(gasRefund)

  computation.vmState.db(readOnly=false):
    db.setStorage(computation.msg.storageAddress, slot, value)

proc sload*(computation) =
  let slot = stack.popInt()

  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #      value = state_db.get_storage(
  #          address=computation.msg.storage_address,
  #          slot=slot,
  #      )
  #  computation.stack.push(value)
