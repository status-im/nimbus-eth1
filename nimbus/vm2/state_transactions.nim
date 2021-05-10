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
  ../config,
  ../constants,
  ../db/accounts_cache,
  ../transaction,
  ./computation,
  ./interpreter_dispatch,
  ./interpreter/[forks_list, gas_costs, gas_meter],
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
      vmState.chainDB.config.toFork(vmState.blockHeader.blockNumber)
  vmState.gasCosts = vmState.fork.forkToSchedule

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
