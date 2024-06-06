# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/strutils,
  results,
  ../../common/common,
  ../../db/ledger,
  ../../transaction/call_evm,
  ../../transaction/call_common,
  ../../transaction,
  ../../vm_state,
  ../../vm_types,
  ../../constants,
  ../validate

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc eip1559BaseFee(header: BlockHeader; fork: EVMFork): UInt256 =
  ## Actually, `baseFee` should be 0 for pre-London headers already. But this
  ## function just plays safe. In particular, the `test_general_state_json.nim`
  ## module modifies this block header `baseFee` field unconditionally :(.
  if FkLondon <= fork:
    result = header.baseFee

proc commitOrRollbackDependingOnGasUsed(
    vmState: BaseVMState;
    accTx: LedgerSpRef;
    header: BlockHeader;
    tx: Transaction;
    gasBurned: GasInt;
    priorityFee: GasInt;
      ): Result[GasInt, string] =
  # Make sure that the tx does not exceed the maximum cumulative limit as
  # set in the block header. Again, the eip-1559 reference does not mention
  # an early stop. It would rather detect differing values for the  block
  # header `gasUsed` and the `vmState.cumulativeGasUsed` at a later stage.
  if header.gasLimit < vmState.cumulativeGasUsed + gasBurned:
    try:
      vmState.stateDB.rollback(accTx)
      return err("invalid tx: block header gasLimit reached. gasLimit=$1, gasUsed=$2, addition=$3" % [
        $header.gasLimit, $vmState.cumulativeGasUsed, $gasBurned])
    except ValueError as ex:
      return err(ex.msg)
  else:
    # Accept transaction and collect mining fee.
    vmState.stateDB.commit(accTx)
    vmState.stateDB.addBalance(vmState.coinbase(), gasBurned.u256 * priorityFee.u256)
    vmState.cumulativeGasUsed += gasBurned

    # Return remaining gas to the block gas counter so it is
    # available for the next transaction.
    vmState.gasPool += tx.gasLimit - gasBurned
    return ok(gasBurned)

proc processTransactionImpl(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork;
      ): Result[GasInt, string] =
  ## Modelled after `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  ## which provides a backward compatible framwork for EIP1559.

  let
    roDB = vmState.readOnlyStateDB
    baseFee256 = header.eip1559BaseFee(fork)
    baseFee = baseFee256.truncate(GasInt)
    tx = eip1559TxNormalization(tx, baseFee)
    priorityFee = min(tx.maxPriorityFee, tx.maxFee - baseFee)
    excessBlobGas = header.excessBlobGas.get(0'u64)

  # Return failure unless explicitely set `ok()`
  var res: Result[GasInt, string] = err("")

  # buy gas, then the gas goes into gasMeter
  if vmState.gasPool < tx.gasLimit:
    return err("gas limit reached. gasLimit=" & $vmState.gasPool &
      ", gasNeeded=" & $tx.gasLimit)

  vmState.gasPool -= tx.gasLimit

  # Actually, the eip-1559 reference does not mention an early exit.
  #
  # Even though database was not changed yet but, a `persist()` directive
  # before leaving is crucial for some unit tests that us a direct/deep call
  # of the `processTransaction()` function. So there is no `return err()`
  # statement, here.
  let txRes = roDB.validateTransaction(tx, sender, header.gasLimit, baseFee256, excessBlobGas, fork)
  if txRes.isOk:

    # EIP-1153
    vmState.stateDB.clearTransientStorage()

    # Execute the transaction.
    vmState.captureTxStart(tx.gasLimit)
    let
      accTx = vmState.stateDB.beginSavepoint
      gasBurned = tx.txCallEvm(sender, vmState, fork).valueOr:
                   return err("Evm Error: " & $error.code)
    vmState.captureTxEnd(tx.gasLimit - gasBurned)

    res = commitOrRollbackDependingOnGasUsed(vmState, accTx, header, tx, gasBurned, priorityFee)
  else:
    res = err(txRes.error)

  if vmState.generateWitness:
    vmState.stateDB.collectWitnessData()
  vmState.stateDB.persist(clearEmptyAccount = fork >= FkSpurious)

  return res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBeaconBlockRoot*(vmState: BaseVMState, beaconRoot: Hash256):
                              Result[void, string] =
  ## processBeaconBlockRoot applies the EIP-4788 system call to the
  ## beacon block root contract. This method is exported to be used in tests.
  ## If EIP-4788 is enabled, we need to invoke the beaconroot storage
  ## contract with the new root.
  let
    statedb = vmState.stateDB
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      gasPrice : 0.GasInt,
      to       : BEACON_ROOTS_ADDRESS,
      input    : @(beaconRoot.data),

      # It's a systemCall, no need for other knicks knacks
      sysCall     : true,
      noAccessList: true,
      noIntrinsic : true,
      noGasCharge : true,
      noRefund    : true,
    )

  # runComputation a.k.a syscall/evm.call
  let res = call.runComputation().valueOr:
              return err("Syscall error: " & $error.code)
  if res.isError:
    return err("processBeaconBlockRoot: " & res.error)

  statedb.persist(clearEmptyAccount = true)
  ok()

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader; ## Header for the block containing the current tx
    fork:    EVMFork;
      ): Result[GasInt,string] =
  vmState.processTransactionImpl(tx, sender, header, fork)

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  EthAddress;  ## tx.getSender or tx.ecRecover
    header:  BlockHeader;
      ): Result[GasInt,string] =
  let fork = vmState.com.toEVMFork(header.forkDeterminationInfo)
  vmState.processTransaction(tx, sender, header, fork)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
