# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when not defined(vm2_enabled):
  {.fatal: "Flags \"vm2_enabled\" must be defined"}
when defined(evmc_enabled):
  {.fatal: "Flags \"evmc_enabled\" and \"vm2_enabled\" are mutually exclusive"}

import
  options, sets,
  eth/common, chronicles, ../db/accounts_cache,
  ../transaction,
  ./computation, ./interpreter, ./state, ./types

proc setupComputation*(vmState: BaseVMState, tx: Transaction, sender: EthAddress, fork: Fork) : Computation =
  var gas = tx.gasLimit - tx.intrinsicGas(fork)
  assert gas >= 0

  vmState.setupTxContext(
    origin = sender,
    gasPrice = tx.gasPrice,
    forkOverride = some(fork)
  )

  let msg = Message(
    kind: if tx.isContractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: gas,
    sender: sender,
    contractAddress: tx.getRecipient(),
    codeAddress: tx.to,
    value: tx.value,
    data: tx.payload
    )

  result = newComputation(vmState, msg)
  doAssert result.isOriginComputation

proc execComputation*(c: Computation) =
  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

  c.execCallOrCreate()

  if c.isSuccess:
    c.refundSelfDestruct()
    shallowCopy(c.vmState.suicides, c.suicides)
    shallowCopy(c.vmState.logEntries, c.logEntries)
    c.vmState.touchedAccounts.incl c.touchedAccounts

  c.vmstate.status = c.isSuccess

proc refundGas*(c: Computation, tx: Transaction, sender: EthAddress) =
  let maxRefund = (tx.gasLimit - c.gasMeter.gasRemaining) div 2
  c.gasMeter.returnGas min(c.getGasRefund(), maxRefund)
  c.vmState.mutateStateDB:
    db.addBalance(sender, c.gasMeter.gasRemaining.u256 * tx.gasPrice.u256)
