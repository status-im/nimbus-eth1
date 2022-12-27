# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../constants,
  ../db/accounts_cache,
  ../transaction,
  ./computation,
  ./interpreter_dispatch,
  ./interpreter/[gas_costs, gas_meter],
  ./message,
  ./state,
  ./types,
  chronicles,
  chronos,
  eth/common/eth_types,
  sets

proc setupTxContext*(vmState: BaseVMState, origin: EthAddress, gasPrice: GasInt, forkOverride=none(EVMFork)) =
  ## this proc will be called each time a new transaction
  ## is going to be executed
  vmState.txOrigin = origin
  vmState.txGasPrice = gasPrice
  vmState.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.com.toEVMFork(vmState.blockNumber)
  vmState.gasCosts = vmState.fork.forkToSchedule


# FIXME-awkwardFactoring: the factoring out of the pre and
# post parts feels awkward to me, but for now I'd really like
# not to have too much duplicated code between sync and async.
# --Adam

proc preExecComputation(c: Computation) =
  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

proc postExecComputation(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
    shallowCopy(c.vmState.selfDestructs, c.selfDestructs)
    shallowCopy(c.vmState.logEntries, c.logEntries)
    c.vmState.touchedAccounts.incl c.touchedAccounts

  c.vmState.status = c.isSuccess

proc execComputation*(c: Computation) =
  c.preExecComputation()
  c.execCallOrCreate()
  c.postExecComputation()

# FIXME-duplicatedForAsync
proc asyncExecComputation*(c: Computation): Future[void] {.async.} =
  c.preExecComputation()
  await c.asyncExecCallOrCreate()
  c.postExecComputation()
