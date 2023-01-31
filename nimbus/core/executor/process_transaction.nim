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
  ../../common/common,
  ../../db/accounts_cache,
  ../../transaction/call_evm,
  ../../transaction,
  ../../vm_state,
  ../../vm_types,
  ../validate,
  ./executor_helpers,
  chronicles,
  stew/results

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc eip1559BaseFee(header: BlockHeader; fork: EVMFork): UInt256 =
  ## Actually, `baseFee` should be 0 for pre-London headers already. But this
  ## function just plays safe. In particular, the `test_general_state_json.nim`
  ## module modifies this block header `baseFee` field unconditionally :(.
  if FkLondon <= fork:
    result = header.baseFee

proc processTransactionImpl(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork): Result[GasInt,void]
    # wildcard exception, wrapped below
    {.gcsafe, raises: [Exception].} =
  ## Modelled after `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  ## which provides a backward compatible framwork for EIP1559.

  #trace "Sender", sender
  #trace "txHash", rlpHash = ty.rlpHash

  let
    roDB = vmState.readOnlyStateDB
    baseFee256 = header.eip1559BaseFee(fork)
    baseFee = baseFee256.truncate(GasInt)
    tx = eip1559TxNormalization(tx, baseFee, fork)
    priorityFee = min(tx.maxPriorityFee, tx.maxFee - baseFee)
    miner = vmState.coinbase()

  # Return failure unless explicitely set `ok()`
  result = err()

  # Actually, the eip-1559 reference does not mention an early exit.
  #
  # Even though database was not changed yet but, a `persist()` directive
  # before leaving is crucial for some unit tests that us a direct/deep call
  # of the `processTransaction()` function. So there is no `return err()`
  # statement, here.
  if roDB.validateTransaction(tx, sender, header.gasLimit, baseFee256, fork):

    # Execute the transaction.
    let
      accTx = vmState.stateDB.beginSavepoint
      gasBurned = tx.txCallEvm(sender, vmState, fork)

    # Make sure that the tx does not exceed the maximum cumulative limit as
    # set in the block header. Again, the eip-1559 reference does not mention
    # an early stop. It would rather detect differing values for the  block
    # header `gasUsed` and the `vmState.cumulativeGasUsed` at a later stage.
    if header.gasLimit < vmState.cumulativeGasUsed + gasBurned:
      vmState.stateDB.rollback(accTx)
      debug "invalid tx: block header gasLimit reached",
        maxLimit = header.gasLimit,
        gasUsed  = vmState.cumulativeGasUsed,
        addition = gasBurned
    else:
      # Accept transaction and collect mining fee.
      vmState.stateDB.commit(accTx)
      vmState.stateDB.addBalance(miner, gasBurned.u256 * priorityFee.u256)
      vmState.cumulativeGasUsed += gasBurned
      result = ok(gasBurned)

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
    vmState.stateDB.collectWitnessData()
  vmState.stateDB.persist(clearCache = false)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork): Result[GasInt,void]
    {.gcsafe, raises: [CatchableError].} =
  ## Process the transaction, write the results to accounts db. The function
  ## returns the amount of gas burned if executed.
  safeExecutor("processTransaction"):
    result = vmState.processTransactionImpl(tx, sender, header, fork)

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader): Result[GasInt,void]
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `processTransaction()` with `*fork* derived
  ## from the `vmState` argument.
  ##
  ## FIXME-Adam: Hmm, I'm getting the block number and timestamp from
  ## the header; is that incorrect?
  let fork = vmState.com.toEVMFork(header.forkDeterminationInfoForHeader)
  vmState.processTransaction(tx, sender, header, fork)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
