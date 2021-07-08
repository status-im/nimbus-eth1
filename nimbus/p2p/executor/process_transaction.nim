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
  std/[sets],
  ../../db/accounts_cache,
  ../../forks,
  ../../transaction/call_evm,
  ../../vm_state,
  ../../vm_types,
  ../validate,
  ./executor_helpers,
  chronicles,
  eth/common

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc eip1559TxNormalization(tx: Transaction): Transaction =
  result = tx
  if tx.txType < TxEip1559:
    result.maxPriorityFee = tx.gasPrice
    result.maxFee = tx.gasPrice


proc processTransactionImpl(tx: Transaction, sender: EthAddress,
                            vmState: BaseVMState, fork: Fork): GasInt
                              # wildcard exception, wrapped below
                              {.gcsafe, raises: [Exception].} =
  trace "Sender", sender
  trace "txHash", rlpHash = tx.rlpHash

  var tx = eip1559TxNormalization(tx)
  var priorityFee: GasInt
  if fork >= FkLondon:
    # priority fee is capped because the base fee is filled first
    let baseFee = vmState.blockHeader.baseFee.truncate(GasInt)
    priorityFee = min(tx.maxPriorityFee, tx.maxFee - baseFee)
    # signer pays both the priority fee and the base fee
    # tx.gasPrice now is the effective gasPrice
    tx.gasPrice = priorityFee + baseFee

  let miner = vmState.coinbase()
  if validateTransaction(vmState, tx, sender, fork):
    result = txCallEvm(tx, sender, vmState, fork)

    # miner fee
    if fork >= FkLondon:
      # miner only receives the priority fee;
      # note that the base fee is not given to anyone (it is burned)
      let txFee = result.u256 * priorityFee.u256
      vmState.accountDb.addBalance(miner, txFee)
    else:
      let txFee = result.u256 * tx.gasPrice.u256
      vmState.accountDb.addBalance(miner, txFee)

  vmState.cumulativeGasUsed += result

  vmState.mutateStateDB:
    for deletedAccount in vmState.selfDestructs:
      db.deleteAccount deletedAccount

    if fork >= FkSpurious:
      vmState.touchedAccounts.incl(miner)
      # EIP158/161 state clearing
      for account in vmState.touchedAccounts:
        if db.accountExists(account) and db.isEmptyAccount(account):
          debug "state clearing", account
          db.deleteAccount(account)

  if vmState.generateWitness:
    vmState.accountDb.collectWitnessData()
  vmState.accountDb.persist(clearCache = false)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processTransaction*(tx: Transaction, sender: EthAddress,
                         vmState: BaseVMState, fork: Fork): GasInt
                            {.gcsafe, raises: [Defect,CatchableError].} =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  safeExecutor("processTransaction"):
    result = tx.processTransactionImpl(sender, vmState, fork)

proc processTransaction*(tx: Transaction, sender: EthAddress,
                         vmState: BaseVMState): GasInt
                            {.gcsafe, raises: [Defect,CatchableError].} =
  ## Same as the other prototype variant with the `fork` argument derived
  ## from `vmState` in a canonical way
  safeExecutor("processTransaction"):
    result = tx.processTransaction(sender, vmState, vmState.getForkUnsafe)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
