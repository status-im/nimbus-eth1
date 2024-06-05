# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/eth_types,
  ../constants,
  ../db/ledger,
  ../transaction,
  ./computation,
  ./interpreter_dispatch,
  ./interpreter/gas_costs,
  ./message,
  ./state,
  ./types

{.push raises: [].}

proc setupTxContext*(vmState: BaseVMState,
                     txCtx: sink TxContext,
                     forkOverride=none(EVMFork)) =
  ## this proc will be called each time a new transaction
  ## is going to be executed
  vmState.txCtx = system.move(txCtx)
  vmState.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.determineFork
  vmState.gasCosts = vmState.fork.forkToSchedule

proc preExecComputation(c: Computation) =
  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

proc postExecComputation(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
  c.vmState.status = c.isSuccess

proc execComputation*(c: Computation)
    {.gcsafe, raises: [CatchableError].} =
  c.preExecComputation()
  c.execCallOrCreate()
  c.postExecComputation()

template execSysCall*(c: Computation) =
  # A syscall to EVM doesn't require
  # a pre or post ceremony
  c.execCallOrCreate()
