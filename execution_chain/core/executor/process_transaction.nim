# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/strformat,
  results,
  ../../common/common,
  ../../db/ledger,
  ../../transaction/call_evm,
  ../../transaction/call_common,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../constants,
  ../eip4844,
  ../eip7691,
  ../validate


export results, call_common

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func eip1559BaseFee(header: Header; fork: EVMFork): UInt256 =
  ## Actually, `baseFee` should be 0 for pre-London headers already. But this
  ## function just plays safe. In particular, the `test_general_state_json.nim`
  ## module modifies this block header `baseFee` field unconditionally :(.
  if FkLondon <= fork:
    result = header.baseFeePerGas.get(0.u256)

proc commitOrRollbackDependingOnGasUsed(
    vmState: BaseVMState;
    accTx: LedgerSpRef;
    header: Header;
    tx: Transaction;
    gasUsed: GasInt;
    priorityFee: GasInt;
    blobGasUsed: GasInt;
      ): Result[void, string] =
  # Make sure that the tx does not exceed the maximum cumulative limit as
  # set in the block header. Again, the eip-1559 reference does not mention
  # an early stop. It would rather detect differing values for the  block
  # header `gasUsed` and the `vmState.cumulativeGasUsed` at a later stage.
  if header.gasLimit < vmState.cumulativeGasUsed + gasUsed:
    vmState.ledger.rollback(accTx)
    err(&"invalid tx: block header gasLimit reached. gasLimit={header.gasLimit}, gasUsed={vmState.cumulativeGasUsed}, addition={gasUsed}")
  else:
    # Accept transaction and collect mining fee.
    vmState.ledger.commit(accTx)
    vmState.ledger.addBalance(vmState.coinbase(), gasUsed.u256 * priorityFee.u256)
    vmState.cumulativeGasUsed += gasUsed

    # Return remaining gas to the block gas counter so it is
    # available for the next transaction.
    vmState.gasPool += tx.gasLimit - gasUsed
    vmState.blobGasUsed += blobGasUsed
    ok()

proc processTransactionImpl(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  Address;  ## tx.recoverSender
    header:  Header; ## Header for the block containing the current tx
      ): Result[LogResult, string] =
  ## Modelled after `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  ## which provides a backward compatible framwork for EIP1559.

  let
    fork = vmState.fork
    roDB = vmState.readOnlyLedger
    baseFee256 = header.eip1559BaseFee(fork)
    baseFee = baseFee256.truncate(GasInt)
    priorityFee = min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFee)
    excessBlobGas = header.excessBlobGas.get(0'u64)

  # buy gas, then the gas goes into gasMeter
  if vmState.gasPool < tx.gasLimit:
    return err("gas limit reached. gasLimit=" & $vmState.gasPool &
      ", gasNeeded=" & $tx.gasLimit)

  vmState.gasPool -= tx.gasLimit

  # blobGasUsed will be added to vmState.blobGasUsed if the tx is ok.
  let
    blobGasUsed = tx.getTotalBlobGas
    maxBlobGasPerBlock = getMaxBlobGasPerBlock(vmState.fork >= FkPrague)
  if vmState.blobGasUsed + blobGasUsed > maxBlobGasPerBlock:
    return err("blobGasUsed " & $blobGasUsed &
      " exceeds maximum allowance " & $maxBlobGasPerBlock)

  # Actually, the eip-1559 reference does not mention an early exit.
  #
  # Even though database was not changed yet but, a `persist()` directive
  # before leaving is crucial for some unit tests that us a direct/deep call
  # of the `processTransaction()` function. So there is no `return err()`
  # statement, here.
  let
    com = vmState.com
    txRes = roDB.validateTransaction(tx, sender, header.gasLimit, baseFee256, excessBlobGas, com, fork)
    res = if txRes.isOk:      
      # Execute the transaction.
      vmState.captureTxStart(tx.gasLimit)
      let
        accTx = vmState.ledger.beginSavepoint
      var
        callResult = tx.txCallEvm(sender, vmState, baseFee)
      vmState.captureTxEnd(tx.gasLimit - callResult.gasUsed)

      let tmp = commitOrRollbackDependingOnGasUsed(
        vmState, accTx, header, tx, callResult.gasUsed, priorityFee, blobGasUsed)

      if tmp.isErr():
        err(tmp.error)
      else:
        ok(move(callResult))
    else:
      err(txRes.error)

  vmState.ledger.persist(clearEmptyAccount = fork >= FkSpurious)

  res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBeaconBlockRoot*(vmState: BaseVMState, beaconRoot: Hash32):
                              Result[void, string] =
  ## processBeaconBlockRoot applies the EIP-4788 system call to the
  ## beacon block root contract. This method is exported to be used in tests.
  ## If EIP-4788 is enabled, we need to invoke the beaconroot storage
  ## contract with the new root.
  let
    ledger = vmState.ledger
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : DEFAULT_GAS_LIMIT.GasInt,
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
  let res = call.runComputation(string)
  if res.len > 0:
    return err("processBeaconBlockRoot: " & res)

  ledger.persist(clearEmptyAccount = true)
  ok()

proc processParentBlockHash*(vmState: BaseVMState, prevHash: Hash32):
                              Result[void, string] =
  ## processParentBlockHash stores the parent block hash in the
  ## history storage contract as per EIP-2935.
  let
    ledger = vmState.ledger
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : DEFAULT_GAS_LIMIT.GasInt,
      gasPrice : 0.GasInt,
      to       : HISTORY_STORAGE_ADDRESS,
      input    : @(prevHash.data),

      # It's a systemCall, no need for other knicks knacks
      sysCall     : true,
      noAccessList: true,
      noIntrinsic : true,
      noGasCharge : true,
      noRefund    : true,
    )

  # runComputation a.k.a syscall/evm.call
  let res = call.runComputation(string)
  if res.len > 0:
    return err("processParentBlockHash: " & res)

  ledger.persist(clearEmptyAccount = true)
  ok()

proc processDequeueWithdrawalRequests*(vmState: BaseVMState): Result[seq[byte], string] =
  ## processDequeueWithdrawalRequests applies the EIP-7002 system call
  ## to the withdrawal requests contract.
  let
    ledger = vmState.ledger
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      gasPrice : 0.GasInt,
      to       : WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,

      # It's a systemCall, no need for other knicks knacks
      sysCall     : true,
      noAccessList: true,
      noIntrinsic : true,
      noGasCharge : true,
      noRefund    : true,
    )

  # runComputation a.k.a syscall/evm.call
  let res = call.runComputation(OutputResult)
  if res.error.len > 0:
    return err("processDequeueWithdrawalRequests: " & res.error)

  ledger.persist(clearEmptyAccount = true)
  ok(res.output)

proc processDequeueConsolidationRequests*(vmState: BaseVMState): Result[seq[byte], string] =
  ## processDequeueConsolidationRequests applies the EIP-7251 system call
  ## to the consolidation requests contract.
  let
    ledger = vmState.ledger
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      gasPrice : 0.GasInt,
      to       : CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS,

      # It's a systemCall, no need for other knicks knacks
      sysCall     : true,
      noAccessList: true,
      noIntrinsic : true,
      noGasCharge : true,
      noRefund    : true,
    )

  # runComputation a.k.a syscall/evm.call
  let res = call.runComputation(OutputResult)
  if res.error.len > 0:
    return err("processDequeueConsolidationRequests: " & res.error)
  ledger.persist(clearEmptyAccount = true)
  ok(res.output)

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  Address;  ## tx.recoverSender
    header:  Header; ## Header for the block containing the current tx
      ): Result[LogResult, string] =
  vmState.processTransactionImpl(tx, sender, header)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
