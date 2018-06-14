# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./impl_std_import, strformat,
  ../../../utils/header,
  ../../../db/[db_chain, state_db]


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

  let
    gasParam = GasParams(kind: Op.Sstore, s_isStorageEmpty: not existing)
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(currentValue, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.storageAddress}[slot] -> {value} ({currentValue})")

  if gasRefund > 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.db(readOnly=false):
    db.setStorage(computation.msg.storageAddress, slot, value)

proc sload*(computation) =
  let slot = stack.popInt()
  var value = 2.u256

  # TODO: with
  # with computation.vm_state.state_db(read_only=True) as state_db:
  #      value = state_db.get_storage(
  #          address=computation.msg.storage_address,
  #          slot=slot,
  #      )
  computation.stack.push(value)
