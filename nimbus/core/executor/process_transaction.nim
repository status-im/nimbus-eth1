# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ../../common/common,
  ../../db/accounts_cache,
  ../../transaction/call_evm,
  ../../transaction,
  ../../vm_state,
  ../../vm_types,
  ../../evm/async/operations,
  ../validate,
  chronicles,
  chronos,
  stew/results

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc eip1559BaseFee(header: BlockHeader; fork: EVMFork): UInt256 =
  ## Actually, `baseFee` should be 0 for pre-London headers already. But this
  ## function just plays safe. In particular, the `test_general_state_json.nim`
  ## module modifies this block header `baseFee` field unconditionally :(.
  if FkLondon <= fork:
    result = header.baseFee

proc commitOrRollbackDependingOnGasUsed(vmState: BaseVMState, accTx: SavePoint,
        header: BlockHeader, tx: Transaction,
        gasBurned: GasInt, priorityFee: GasInt): Result[GasInt, void] {.raises: [Defect, RlpError].} =
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
    return err()
  else:
    # Accept transaction and collect mining fee.
    vmState.stateDB.commit(accTx)
    vmState.stateDB.addBalance(vmState.coinbase(), gasBurned.u256 * priorityFee.u256)
    vmState.cumulativeGasUsed += gasBurned

    # Return remaining gas to the block gas counter so it is
    # available for the next transaction.
    vmState.gasPool += tx.gasLimit - gasBurned
    return ok(gasBurned)

proc asyncProcessTransactionImpl(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork): Future[Result[GasInt,void]]
    # wildcard exception, wrapped below
    {.async, gcsafe.} =
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

  # Return failure unless explicitely set `ok()`
  var res: Result[GasInt,void] = err()

  await ifNecessaryGetAccounts(vmState, @[sender, vmState.coinbase()])
  if tx.to.isSome:
    await ifNecessaryGetCode(vmState, tx.to.get)

  # buy gas, then the gas goes into gasMeter
  if vmState.gasPool < tx.gasLimit:
    debug "gas limit reached",
      gasLimit = vmState.gasPool,
      gasNeeded = tx.gasLimit
    return
  vmState.gasPool -= tx.gasLimit

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

    res = commitOrRollbackDependingOnGasUsed(vmState, accTx, header, tx, gasBurned, priorityFee)

  if vmState.generateWitness:
    vmState.stateDB.collectWitnessData()
  vmState.stateDB.persist(
    clearEmptyAccount = fork >= FkSpurious,
    clearCache = false)

  return res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc asyncProcessTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork): Future[Result[GasInt,void]]
    {.async, gcsafe.} =
  ## Process the transaction, write the results to accounts db. The function
  ## returns the amount of gas burned if executed.
  return await vmState.asyncProcessTransactionImpl(tx, sender, header, fork)

# FIXME-duplicatedForAsync
proc asyncProcessTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader): Future[Result[GasInt,void]]
    {.async, gcsafe.} =
  ## Variant of `asyncProcessTransaction()` with `*fork* derived
  ## from the `vmState` argument.
  let fork = vmState.com.toEVMFork(header.forkDeterminationInfoForHeader)
  return await vmState.asyncProcessTransaction(tx, sender, header, fork)

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork): Result[GasInt,void]
    {.gcsafe, raises: [CatchableError].} =
  return waitFor(vmState.asyncProcessTransaction(tx, sender, header, fork))

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader): Result[GasInt,void]
    {.gcsafe, raises: [CatchableError].} =
  return waitFor(vmState.asyncProcessTransaction(tx, sender, header))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
