# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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
  ../../evm/eip7708,
  ../../constants,
  ../eip4844,
  ../eip7691,
  ../validate


export results, call_common

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func eip1559BaseFee(vmState: BaseVMState; fork: EVMFork): UInt256 =
  ## Actually, `baseFee` should be 0 for pre-London headers already. But this
  ## function just plays safe.
  if FkLondon <= fork:
    result = vmState.blockCtx.baseFeePerGas.get(0.u256)

proc commitOrRollbackDependingOnGasUsed(
    vmState: BaseVMState;
    savePoint: LedgerSpRef;
    tx: Transaction;
    callResult: var LogResult;
    priorityFee: GasInt;
    blobGasUsed: GasInt;
    rollbackReads: bool;
      ): Result[void, string] =
  # Make sure that the tx does not exceed the maximum cumulative limit as
  # set in the vmState.blockCtx. Again, the EIP-1559 reference does not mention
  # an early stop. It would rather detect differing values for the  block
  # header `gasUsed` and the `vmState.cumulativeGasUsed` at a later stage.
  let gasUsed = callResult.gasUsed

  # EIP-8037: block validity is max(blockRegularGas, blockStateGas) <= gasLimit
  if vmState.fork >= FkAmsterdam:
    let limit2d = max(
      vmState.blockRegularGasUsed + callResult.blockRegularGasUsed,
      vmState.blockStateGasUsed + callResult.blockStateGasUsed)
    if vmState.blockCtx.gasLimit < limit2d:
      if vmState.balTrackerEnabled:
        vmState.balTracker.rollbackCallFrame(rollbackReads)
      vmState.ledger.rollback(savePoint)
      return err(&"invalid tx: block gas limit reached (2D). gasLimit={vmState.blockCtx.gasLimit}, regularGas={vmState.blockRegularGasUsed}+{callResult.blockRegularGasUsed}, stateGas={vmState.blockStateGasUsed}+{callResult.blockStateGasUsed}")
  else:
    let limit = vmState.cumulativeGasUsed + gasUsed
    if vmState.blockCtx.gasLimit < limit:
      if vmState.balTrackerEnabled:
        vmState.balTracker.rollbackCallFrame(rollbackReads)
      vmState.ledger.rollback(savePoint)
      return err(&"invalid tx: block gasLimit reached. gasLimit={vmState.blockCtx.gasLimit}, gasUsed={vmState.cumulativeGasUsed}, addition={gasUsed}")

  # Accept transaction and collect mining fee.
  let txFee = gasUsed.u256 * priorityFee.u256
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddBalanceChange(vmState.coinbase(), txFee)
    vmState.balTracker.commitCallFrame()

  vmState.ledger.addBalance(vmState.coinbase(), txFee)
  vmState.ledger.commit(savePoint)
  vmState.cumulativeGasUsed += gasUsed
  vmState.blockRegularGasUsed += callResult.blockRegularGasUsed
  vmState.blockStateGasUsed += callResult.blockStateGasUsed
  vmState.blobGasUsed += blobGasUsed

  # EIP-7708: Emit closure logs for accounts with remaining balance before deletion
  if vmState.fork >= FkAmsterdam:
    emitClosureLogs(vmState, callResult.logEntries)
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  Address;  ## tx.recoverSender
    rollbackReads: bool = false;
      ): Result[LogResult, string] =
  ## Modelled after `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  ## which provides a backward compatible framwork for EIP1559.

  let
    fork = vmState.fork
    roDB = vmState.readOnlyLedger
    baseFee256 = vmState.eip1559BaseFee(fork)
    baseFee = baseFee256.truncate(GasInt)
    priorityFee = min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFee)
    excessBlobGas = vmState.blockCtx.excessBlobGas
    regularGasAvailable = vmState.blockCtx.gasLimit - vmState.blockRegularGasUsed

  # Regular gas is capped at TX_MAX_GAS_LIMIT per EIP-7825.
  # State gas is not checked per-tx; block-end validation enforces
  # max(block_regular_gas_used, block_state_gas_used) <= gas_limit.
  if min(TX_GAS_LIMIT.GasInt, tx.gasLimit) > regularGasAvailable:
    let want = min(TX_GAS_LIMIT.GasInt, tx.gasLimit)
    return err("regular gas used exceeds limit want: " & $want & ", available: " & $regularGasAvailable)

  # blobGasUsed will be added to vmState.blobGasUsed if the tx is ok.
  let
    blobGasUsed = tx.getTotalBlobGas
    maxBlobGasPerBlock = getMaxBlobGasPerBlock(vmState.com, vmState.fork)
  if vmState.blobGasUsed + blobGasUsed > maxBlobGasPerBlock:
    return err("blobGasUsed " & $blobGasUsed &
      " exceeds maximum allowance " & $maxBlobGasPerBlock)

  # Actually, the EIP-1559 reference does not mention an early exit.
  #
  # Even though database was not changed yet but, a `persist()` directive
  # before leaving is crucial for some unit tests that us a direct/deep call
  # of the `processTransaction()` function. So there is no `return err()`
  # statement, here.
  let
    com = vmState.com
    txRes = roDB.validateTransaction(tx, sender, vmState.blockCtx.gasLimit, baseFee256, excessBlobGas, com, fork)
    res = if txRes.isOk:
      # Execute the transaction.
      vmState.captureTxStart(tx.gasLimit)

      if vmState.balTrackerEnabled:
        vmState.balTracker.beginCallFrame()
      let savePoint = vmState.ledger.beginSavePoint()

      var callResult = tx.txCallEvm(sender, vmState, baseFee)
      vmState.captureTxEnd(tx.gasLimit - callResult.gasUsed)

      let tmp = commitOrRollbackDependingOnGasUsed(
        vmState, savePoint, tx, callResult, priorityFee, blobGasUsed, rollbackReads)

      if tmp.isErr():
        err(tmp.error)
      else:
        ok(move(callResult))
    else:
      err(txRes.error)

  vmState.ledger.persist(clearEmptyAccount = fork >= FkSpurious)

  res

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
      gasLimit : 30_000_000.GasInt,
      gasPrice : 0.GasInt,
      to       : BEACON_ROOTS_ADDRESS,
      input    : @(beaconRoot.data),
      sysCall  : true,
    )

  # runComputation a.k.a syscall/evm.call
  # EIP-4788: fail silently
  call.runComputation(void)
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
      gasLimit : 30_000_000.GasInt,
      gasPrice : 0.GasInt,
      to       : HISTORY_STORAGE_ADDRESS,
      input    : @(prevHash.data),
      sysCall  : true,
    )

  # runComputation a.k.a syscall/evm.call
  # EIP-2923: fail silently
  call.runComputation(void)
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
      sysCall  : true,
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
      sysCall  : true,
    )

  # runComputation a.k.a syscall/evm.call
  let res = call.runComputation(OutputResult)
  if res.error.len > 0:
    return err("processDequeueConsolidationRequests: " & res.error)
  ledger.persist(clearEmptyAccount = true)
  ok(res.output)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
