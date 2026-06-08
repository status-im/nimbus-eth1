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
  ../../transaction/system_call,
  ../../transaction/call_types,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../evm/eip7708,
  ../../constants,
  ../eip4844,
  ../eip7691,
  ../validate


export results, call_types

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc commitOrRollbackDependingOnGasUsed(
    vmState: BaseVMState;
    savePoint: LedgerSpRef;
    tx: Transaction;
    callResult: var LogResult;
    blobGasUsed: GasInt;
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
      vmState.ledger.rollback(savePoint)
      return err(&"invalid tx: block gas limit reached (2D). gasLimit={vmState.blockCtx.gasLimit}, regularGas={vmState.blockRegularGasUsed}+{callResult.blockRegularGasUsed}, stateGas={vmState.blockStateGasUsed}+{callResult.blockStateGasUsed}")
  else:
    let limit = vmState.cumulativeGasUsed + gasUsed
    if vmState.blockCtx.gasLimit < limit:
      vmState.ledger.rollback(savePoint)
      return err(&"invalid tx: block gasLimit reached. gasLimit={vmState.blockCtx.gasLimit}, gasUsed={vmState.cumulativeGasUsed}, addition={gasUsed}")

  # Accept transaction and collect mining fee.
  let
    baseFee = vmState.blockCtx.baseFeePerGas
    priorityFee = min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFee)
    txFee = gasUsed.u256 * priorityFee.u256

  callResult.txFee = txFee
  vmState.ledger.addBalance(vmState.coinbase(), txFee)
  vmState.ledger.addBalance(vmState.coinbase(), txFee, checkEmptyAccount = vmState.fork < FkParis)
  vmState.ledger.commit(savePoint)
  vmState.cumulativeGasUsed += gasUsed
  vmState.blockRegularGasUsed += callResult.blockRegularGasUsed
  vmState.blockStateGasUsed += callResult.blockStateGasUsed
  vmState.blobGasUsed += blobGasUsed

  # EIP-7708: Emit closure logs for accounts with remaining balance before deletion
  if vmState.fork >= FkAmsterdam:
    emitClosureLogs(vmState, callResult.logEntries)
  ok()

template validateForInclusion(
    vmState: BaseVMState;
    tx: Transaction;
    sender: Address;
    skipNonceCheck: bool;
    buildError: static bool;
    intrinsicVar, blobGasUsedVar: untyped) =

  template fail(msg: untyped): untyped =
    when buildError:
      return err(msg)
    else:
      return

  let
    com = vmState.com
    fork = vmState.hardFork
    regularGasAvailable = vmState.blockCtx.gasLimit - vmState.blockRegularGasUsed
    stateGasAvailable = vmState.blockCtx.gasLimit - vmState.blockStateGasUsed
    intrinsicVar = tx.intrinsicGas(fork, vmState.blockCtx.gasLimit)

  # Per-tx 2D gas inclusion check: for each dimension the worst-case
  # contribution must fit in the remaining budget.  Block-end
  # validation still enforces
  if fork < Amsterdam:
    let want = min(TX_GAS_LIMIT.GasInt, tx.gasLimit)
    if want > regularGasAvailable:
      fail("regular gas used exceeds limit, want: " & $want & ", available: " & $regularGasAvailable)
  else:
    # https://github.com/ethereum/execution-specs/pull/2703/changes
    # Worst-case regular contribution: tx.gasLimit minus the portion that
    # must go to intrinsic state gas, capped at TX_MAX_GAS_LIMIT.
    let want = min(TX_GAS_LIMIT.GasInt, tx.gasLimit - intrinsicVar.state)
    if want > regularGasAvailable:
      fail("regular gas used exceeds limit, want: " & $want & ", available: " & $regularGasAvailable)

    # Worst-case state contribution: tx.gasLimit minus the portion that
    # must go to intrinsic regular gas.
    let stateGas = tx.gasLimit - intrinsicVar.regular
    if stateGas > stateGasAvailable:
      fail("state gas used exceeds limit, want: " & $stateGas & ", available: " & $stateGasAvailable)

  # blobGasUsed will be added to vmState.blobGasUsed if the tx is ok.
  let
    blobGasUsedVar = tx.getTotalBlobGas
    maxBlobGasPerBlock = getMaxBlobGasPerBlock(com, fork)
  if vmState.blobGasUsed + blobGasUsedVar > maxBlobGasPerBlock:
    fail("blobGasUsed " & $blobGasUsedVar &
      " exceeds maximum allowance " & $maxBlobGasPerBlock)

  validateTxBasic(com, tx, intrinsicVar, fork).isOkOr:
    fail(error)
  vmState.validateTransaction(tx, sender, skipNonceCheck).isOkOr:
    fail(error)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processTransaction*(
    vmState: BaseVMState; ## Parent accounts environment for transaction
    tx:      Transaction; ## Transaction to validate
    sender:  Address;  ## tx.recoverSender
      ): Result[LogResult, string] =
  ## Modelled after `https://eips.ethereum.org/EIPS/eip-1559#specification`_
  ## which provides a backward compatible framwork for EIP1559.

  validateForInclusion(vmState, tx, sender, false, true, intrinsic, blobGasUsed)

  # Execute the transaction.
  vmState.captureTxStart(tx.gasLimit)
  let savePoint = vmState.ledger.beginSavePoint()

  var callResult = tx.txCallEvm(sender, vmState, intrinsic)
  vmState.captureTxEnd(tx.gasLimit - callResult.gasUsed)

  let
    tmp = commitOrRollbackDependingOnGasUsed(
      vmState, savePoint, tx, callResult, blobGasUsed)
    res = if tmp.isErr:
      err(tmp.error)
    else:
      ok(move(callResult))

  if vmState.balTrackerEnabled:
    vmState.balLedger.writeToTxFrameAndBAL(vmState.ledger)
  else:
    vmState.ledger.persist(clearEmptyAccount = vmState.hardFork >= Spurious)

  res

proc prefetchTransaction*(
    vmState: BaseVMState; ## Throwaway accounts environment for prefetching
    tx:      Transaction; ## Transaction to speculatively execute
    sender:  Address;     ## Pre-recovered sender
      ) =

  validateForInclusion(vmState, tx, sender, true, false, intrinsic, blobGasUsed)

  let savePoint = vmState.ledger.beginSavePoint()
  tx.txCallEvm(sender, vmState, intrinsic, discardResult = true)
  vmState.ledger.rollback(savePoint)

proc processBeaconBlockRoot*(vmState: BaseVMState, beaconRoot: Hash32) =
  ## processBeaconBlockRoot applies the EIP-4788 system call to the
  ## beacon block root contract. This method is exported to be used in tests.
  ## If EIP-4788 is enabled, we need to invoke the beaconroot storage
  ## contract with the new root.
  let
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      to       : BEACON_ROOTS_ADDRESS,
      input    : @(beaconRoot.data),
    )

  # EIP-4788: fail silently
  call.systemCall(void)

proc processParentBlockHash*(vmState: BaseVMState, prevHash: Hash32) =
  ## processParentBlockHash stores the parent block hash in the
  ## history storage contract as per EIP-2935.
  let
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      to       : HISTORY_STORAGE_ADDRESS,
      input    : @(prevHash.data),
    )

  # EIP-2923: fail silently
  call.systemCall(void)

proc processDequeueWithdrawalRequests*(vmState: BaseVMState): Result[seq[byte], string] =
  ## processDequeueWithdrawalRequests applies the EIP-7002 system call
  ## to the withdrawal requests contract.
  let
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      to       : WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,
    )

  var res = call.systemCall(OutputResult)
  if res.error.len > 0:
    return err("processDequeueWithdrawalRequests: " & res.error)
  ok(move(res.output))

proc processDequeueConsolidationRequests*(vmState: BaseVMState): Result[seq[byte], string] =
  ## processDequeueConsolidationRequests applies the EIP-7251 system call
  ## to the consolidation requests contract.
  let
    call = CallParams(
      vmState  : vmState,
      sender   : SYSTEM_ADDRESS,
      gasLimit : 30_000_000.GasInt,
      to       : CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS,
    )

  var res = call.systemCall(OutputResult)
  if res.error.len > 0:
    return err("processDequeueConsolidationRequests: " & res.error)
  ok(move(res.output))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
