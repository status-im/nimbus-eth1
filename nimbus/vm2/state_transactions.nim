# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

const
  # needed for compiling locally
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../transaction,
  ./interpreter,
  chronicles,
  eth/common/eth_types,
  options,
  sets

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../config,
    ../constants,
    ../db/accounts_cache,
    ./computation,
    ./interpreter/gas_costs,
    ./state,
    ./types,
    eth/common

else:
  import
    ./interpreter/op_handlers/[oph_defs_kludge, oph_helpers_kludge]

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

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
