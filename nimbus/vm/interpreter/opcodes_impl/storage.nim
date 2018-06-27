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
  var (currentValue, existing) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.storageAddress, slot)

  let
    gasParam = GasParams(kind: Op.Sstore, s_isStorageEmpty: not existing)
    (gasCost, gasRefund) = computation.gasCosts[Sstore].c_handler(currentValue, gasParam)

  computation.gasMeter.consumeGas(gasCost, &"SSTORE: {computation.msg.storageAddress}[slot] -> {value} ({currentValue})")

  if gasRefund > 0:
    computation.gasMeter.refundGas(gasRefund)

  computation.vmState.mutateStateDB:
    db.setStorage(computation.msg.storageAddress, slot, value)

proc sload*(computation) =
  let slot = stack.popInt()
  let (value, found) = computation.vmState.readOnlyStateDB.getStorage(computation.msg.storageAddress, slot)
  if found:
    computation.stack.push value
  else:
    # XXX: raise exception?
    discard

