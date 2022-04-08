# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This source must have the <vm2_enabled> compiler flag set.
#
# why:
#   ../config, ../transaction,  etc include ../vm_* interface files which in
#   turn will refer to the ../vm/* definitions rather than ../vm2/* unless the
#    <vm2_enabled> compiler flag is set.
#
when not defined(vm2_enabled):
  {.error: "NIM flag must be set: -d:vm2_enabled".}

import
  ../chain_config,
  ../constants,
  ../forks,
  ../db/accounts_cache,
  ../transaction,
  ./computation,
  ./interpreter_dispatch,
  ./interpreter/[gas_costs, gas_meter],
  ./message,
  ./state,
  ./types,
  chronicles,
  eth/common,
  eth/common/eth_types,
  options,
  sets

proc setupTxContext*(vmState: BaseVMState, origin: EthAddress, gasPrice: GasInt, forkOverride=none(Fork)) =
  ## this proc will be called each time a new transaction
  ## is going to be executed
  vmState.txOrigin = origin
  vmState.txGasPrice = gasPrice
  vmState.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.chainDB.config.toFork(vmState.blockNumber)
  vmState.gasCosts = vmState.fork.forkToSchedule


proc refundGas*(c: Computation, tx: Transaction, sender: EthAddress) =
  let maxRefund = (tx.gasLimit - c.gasMeter.gasRemaining) div 2
  c.gasMeter.returnGas min(c.getGasRefund(), maxRefund)
  c.vmState.mutateStateDB:
    db.addBalance(sender, c.gasMeter.gasRemaining.u256 * tx.gasPrice.u256)


proc execComputation*(c: Computation) =
  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

  c.execCallOrCreate()

  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
    shallowCopy(c.vmState.selfDestructs, c.selfDestructs)
    shallowCopy(c.vmState.logEntries, c.logEntries)
    c.vmState.touchedAccounts.incl c.touchedAccounts

  c.vmState.status = c.isSuccess
