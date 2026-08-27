# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  eth/common/transactions,
  eth/common/receipts,
  eth/common/accounts,
  ../evm/state,
  ../evm/evm_errors,
  ../evm/interpreter/gas_meter,
  ../evm/interpreter/gas_costs,
  ../evm/precompiles,
  ../evm/computation,
  ../evm/interpreter_dispatch,
  ../core/eip8141,
  ./call_types

from ../core/eip4844 import getBlobBaseFee, getTotalBlobGas
from ../core/eip7702 import parseDelegationAddress
from ../core/eip8037 import CREATE_ACCOUNT_STATE_GAS

proc beginFrameProcessing(params: CallParams): Result[void, string] =
  let
    sigHash = computeSigHash(params.tx[])
    vmState = params.vmState
    tx = params.tx
    fork = vmState.hardFork

  vmState.enableFrame()

  vmState.frameCtx.resolvedSigners.setLen(tx.signatures.len)
  for i, sig in tx.signatures:
    let address = ? validateSignature(sig, tx.sender, sigHash)
    vmState.frameCtx.resolvedSigners[i] = address

  vmState.frameCtx.signatureHash = sigHash

  vmState.txCtx = TxContext(
    origin            : params.sender,
    effectiveGasPrice : params.effectiveGasPrice,
    blobBaseFee       : getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
    tx                : params.tx,
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.refundCounter = 0
  ok()

proc executeDefaultVerifyCode(vmState: BaseVMState,
                              frame: TransactionFrame,
                              resolvedTarget: Address): EvmResult[bool] =
  let
    allowedScope = frame.flags.uint and APPROVE_SCOPE_MASK
    tx = vmState.txCtx.tx

  # The frame is not allowed to approve anything.
  if allowedScope == 0:
    return ok(false)

  let signatureIndex = if (APPROVE_EXECUTION_FLAG and allowedScope) != 0: 0 else: 1

  # There is no signature entry at the authorizing index.
  if tx.signatures.len <= signatureIndex:
    return ok(false)

  let
    signature = tx.signatures[signatureIndex]

  # Only a protocol-validated secp256k1 signature authorizes.
  if signature.scheme != SCHEME_SECP256K1:
    return ok(false)

  # The signature must cover the canonical signature hash.
  if signature.msg.len != 0:
    return ok(false)

  # The signature must come from the frame's resolved target.
  if vmState.frameCtx.resolvedSigners[signatureIndex] != resolvedTarget:
    return ok(false)

  let approved = ? vmState.attemptApproval(frame, allowedScope, resolvedTarget)
  if not approved:
    return ok(false)

  ok(true)

func gasAccountCheck(ledger: LedgerRef; address: Address): GasInt =
  if not ledger.inAccessList(address):
    ledger.accessList(address)
    COLD_ACCOUNT_ACCESS_8038
  else:
    WARM_ACCESS

proc resolveDelegatedCodeAddress(vmState: BaseVMState,
                                 msg: Message,
                                 gasMeter: var GasMeter): EvmResult[CodeBytesRef] =
  # Avoid accessing ledger if it's a precompile address
  if isPrecompile(vmState.fork, msg.codeAddress):
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(msg.codeAddress)
    msg.flags.incl MsgFlags.Precompile
    return ok(CodeBytesRef(nil))

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(msg.codeAddress)

  let
    ledger = vmState.ledger
    code = ledger.getCode(msg.codeAddress)
    delegateTo = parseDelegationAddress(code).valueOr:
      return ok(code)

  let
    accessGas = ledger.gasAccountCheck(delegateTo)

  ? gasMeter.consumeGas(accessGas, "executeFrame")
  msg.flags.incl MsgFlags.Delegated
  msg.delegateTo = delegateTo
  ok(code)

proc createEVMFromFrame(vmState: BaseVMState,
                        frame: TransactionFrame,
                        gasMeter: var GasMeter,
                        resolvedTarget: Address): EvmResult[Computation] =
  let
    ledger = vmState.ledger

  if frame.value.isZero.not and not ledger.isAccountAlive(resolvedTarget):
    ? vmState.chargeFrameStateGas(CREATE_ACCOUNT_STATE_GAS, "create EVM from frame")

  let
    msg = Message(
      kind:              CallKind.Call,
      gas:               0,
      stateGasReservoir: 0,
      currentTarget:     resolvedTarget,
      codeAddress:       resolvedTarget,
      delegateTo:        resolvedTarget,
      sender:            vmState.txCtx.origin,
      value:             frame.value,
      data:              frame.data,
      flags:             if frame.mode == VERIFY_MODE: {MsgFlags.Static}
                         else: {}
    )
    code = ? resolveDelegatedCodeAddress(vmState, msg, gasMeter)
    computation = newComputation(vmState, false, msg, gasMeter, code)

  vmState.captureStart(computation, vmState.txCtx.origin, resolvedTarget,
                       false, frame.data,
                       frame.gasLimit, frame.value)
  ok(computation)

proc executeFrame(vmState: BaseVMState,
                  frame: TransactionFrame): EvmResult[int64] =
  let
    tx = vmState.getTransaction()
    resolvedTarget = resolveFrameTarget(tx, frame.addr)

  # Checkpoint at frame entry, before any charge: a failing frame's
  # state gas restores to here, and any edits it made to earlier
  # receipts are undone with it.

  let
    entrySnapshot = vmState.copyFrameContext()
    stateBudget = frame.stateGasLimit
    executionBudget = frame.gasLimit
    ledger = vmState.ledger

  var
    gasMeter = GasMeter.init(executionBudget)

  # Warm up the frame's access sets
  ledger.accessList(vmState.coinbase)

  # Adds the correct subset of precompiles.
  for c in activePrecompiles(vmState.fork):
    ledger.accessList(c)

  # Charge the resolved target's access
  let
    accessGas = ledger.gasAccountCheck(resolvedTarget)

  gasMeter.consumeGas(accessGas, "executeFrame").isOkOr:
    vmState.frameOutcomeFailure(executionBudget)
    return err(error)

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(resolvedTarget)

  if frame.mode == VERIFY_MODE and
     not isPrecompile(vmState.fork, resolvedTarget) and
     ledger.getCodeHash(resolvedTarget) == EMPTY_CODE_HASH:

    let
      status = executeDefaultVerifyCode(vmState, frame, resolvedTarget).valueOr:
        vmState.restoreFrameContext(entrySnapshot)
        vmState.frameOutcomeFailure(executionBudget)
        return err(error)

    vmState.frameOutcome(status,
      executionBudget - gasMeter.executionGasLeft,
      stateBudget - vmState.frameStateGasLeft,
    )

    return ok(0)

  if frame.value.isZero.not:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(vmState.txCtx.origin)
    let
      callerBalance = ledger.getBalance(vmState.txCtx.origin)
    if callerBalance < frame.value:
      vmState.frameOutcomeFailure(executionBudget - gasMeter.executionGasLeft)
      return err(evmErr(EvmInvalidParam))

  let
    evm = createEVMFromFrame(vmState, frame, gasMeter, resolvedTarget).valueOr:
      vmState.restoreFrameContext(entrySnapshot)
      vmState.frameOutcomeFailure(executionBudget)
      return err(error)

  execCallOrCreate(evm)

  if evm.isError:
    # The frame failed: `process_call` rolled its state gas back
    # to the call, and this restore extends the rollback over the
    # frame-entry charge.
    vmState.restoreFrameContext(entrySnapshot)

  let
    executionGasUsed = executionBudget - evm.gasMeter.executionGasLeft
    stateGasUsed = stateBudget - vmState.frameStateGasLeft

  if evm.isSuccess:
    vmState.frameOutcomeSuccess(executionGasUsed, stateGasUsed, evm.logEntries)
  else:
    vmState.frameOutcomeFailure(executionGasUsed, stateGasUsed)

  ok(evm.gasMeter.refundCounter)

type
  AtomicBatch = object
    firstFrameIndex: int
    stateSnapshot  : LedgerSpRef
    frameSnapshot  : FrameSnapshot
    refundCounter  : int64

  TransactionOutput = object
    gasLeft     : GasInt
    stateGasLeft: GasInt
    stateGasUsed: GasInt

proc unrollAtomicBatch(vmState: BaseVMState, batch: var AtomicBatch) =
  # Static validity bans approval scopes on batch frames, so the
  # unroll can never move the approval context.
  doAssert vmState.payer == batch.frameSnapshot.payer
  doAssert vmState.senderApproved == batch.frameSnapshot.senderApproved

  var
    snapshot = vmState.frameCtx.snapshot

  vmState.ledger.rollback(batch.stateSnapshot)
  vmState.restoreFrameContext(batch.frameSnapshot)
  vmState.refundCounter = batch.refundCounter
  vmState.frameCtx.snapshot.receipts = move(snapshot.receipts)
  snapshot = vmState.frameCtx.snapshot

  # Logs emptied and state gas zeroed.
  # Frame consumed gas remains charged.
  for i in batch.firstFrameIndex..<snapshot.receipts.len:
    snapshot.receipts[i].stateGasUsed = 0
    snapshot.receipts[i].logs.setLen(0)

  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc commitAtomicBatch(vmState: BaseVMState, batch: var AtomicBatch) =
  vmState.ledger.commit(batch.stateSnapshot)
  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc processFrames(vmState: BaseVMState): Result[TransactionOutput, string] =
  let
    tx = vmState.getTransaction()
    ledger = vmState.ledger

  ledger.accessList(tx.sender)

  var
    openBatch = Opt.none(AtomicBatch)
    skipBatch = false

  for index, frame in tx.frames:
    vmState.frameCtx.snapshot.currentFrameIndex = index
    let
      hasBatchFlag = (frame.flags and ATOMIC_BATCH_FLAG) != 0

    if hasBatchFlag and openBatch.isNone:
      openBatch = Opt.some(AtomicBatch(
        firstFrameIndex: index,
        stateSnapshot  : ledger.beginSavePoint(),
        frameSnapshot  : vmState.copyFrameContext(),
        refundCounter  : vmState.refundCounter,
      ))

    if skipBatch:
      # A frame of a failed atomic batch never executes; its
      # zero-usage receipt makes its allotted gas — in both
      # dimensions — count as unused.
      vmState.frameOutcomeSkipped()
      if not hasBatchFlag:
        openBatch = Opt.none(AtomicBatch)
        skipBatch = false
      continue

    if frame.mode == SENDER_MODE and not vmState.senderApproved:
      return err("SENDER frame before execution approval")

    # The ORIGIN opcode returns the frame's caller at every call depth.
    if frame.mode == SENDER_MODE:
      vmState.txCtx.origin = tx.sender
    else:
      vmState.txCtx.origin = FRAME_ENTRY_POINT

    # Seed the frame's state gas pool from its declared budget.
    vmState.frameCtx.snapshot.stateGasLeft = frame.stateGasLimit

    var
      # TODO: Optimize without copying?
      accessListSnapshot = ledger.copyAccessList()
      selfDestructSnapshot = ledger.copySelfDestruct()

    let
      refundCounter = executeFrame(vmState, frame).valueOr:
        ledger.restoreAccessList(accessListSnapshot)
        ledger.restoreSelfDestruct(selfDestructSnapshot)
        return err("executeFrame: " & $error.code)
      receipt = vmState.frameCtx.snapshot.receipts[^1].addr

    if frame.mode == VERIFY_MODE and receipt.status == FRAME_STATUS_FAILURE:
      # Keep access list here, no need to restore to snapshot.
      ledger.restoreSelfDestruct(selfDestructSnapshot)
      return err("VERIFY frame failed")

    vmState.refundCounter += refundCounter

    let
      terminatesBatch = openBatch.isSome and not hasBatchFlag

    if receipt.status == FRAME_STATUS_FAILURE and openBatch.isSome:
      vmState.unrollAtomicBatch(openBatch.value)
      if terminatesBatch:
        openBatch = Opt.none(AtomicBatch)
      else:
        skipBatch = true
    elif terminatesBatch:
      vmState.commitAtomicBatch(openBatch.value)
      openBatch = Opt.none(AtomicBatch)

  if vmState.payer.isNone:
    return err("no frame approved gas payment")

  # Settle both dimensions from the final receipts; every frame has
  # exactly one.
  var
    unusedExecutionGas = 0.GasInt
    unusedStateGas = 0.GasInt
    stateGasUsed = 0.GasInt

  for i in 0..<tx.frames.len:
    let
      frame = tx.frames[i].addr
      receipt = vmState.frameCtx.snapshot.receipts[i].addr

    unusedExecutionGas += frame.gasLimit - receipt.gasUsed
    unusedStateGas += frame.stateGasLimit - receipt.stateGasUsed
    stateGasUsed += receipt.stateGasUsed

  ok(TransactionOutput(
    gasLeft     : unusedExecutionGas,
    stateGasLeft: unusedStateGas,
    stateGasUsed: stateGasUsed,
  ))

type
  GasSettlement = object
    gasUsed         : GasInt
    executionGasUsed: GasInt
    stateGasUsed    : GasInt

func settleFrameTransactionGas(
        standardGasLimit: GasInt,
        calldataFloor: GasInt,
        txUnusedGas: GasInt,
        refundCounter: GasInt,
        txStateGas: GasInt): GasSettlement =
  let
    gasUsedBeforeRefund = standardGasLimit - txUnusedGas
    appliedRefund = min(refundCounter, gasUsedBeforeRefund div 5)
    gasUsedAfterRefund = gasUsedBeforeRefund - appliedRefund
    payerExecutionGasUsed = GasInt(
      max(
        int64(gasUsedAfterRefund) - int64(txStateGas),
        int64(calldataFloor)
      )
    )
    blockExecutionGasUsed = max(
      gasUsedBeforeRefund - txStateGas,
      calldataFloor
    )

  GasSettlement(
    gasUsed         : payerExecutionGasUsed + txStateGas,
    executionGasUsed: blockExecutionGasUsed,
    stateGasUsed    : txStateGas,
  )

func blobGasFee(vmState: BaseVMState): UInt256 =
  getTotalBlobGas(vmState.txCtx.tx.versionedHashes.len).u256 *
    vmState.txCtx.blobBaseFee

proc disburseFrameGasFees(vmState: BaseVMState, gasUsed: GasInt) =
  # `process_frames` invalidates the transaction unless a frame
  # approved payment.
  let
    payer = vmState.payer()
  doAssert payer.isSome

  let
    blobGasFee = vmState.blobGasFee()
    chargedFee = gasUsed.u256 * vmState.txCtx.effectiveGasPrice.u256 + blobGasFee
    payerRefund = vmState.getMaxCost() - chargedFee
    priorityFeePerGas = vmState.txCtx.effectiveGasPrice - vmState.blockCtx.baseFeePerGas
    transactionFee = gasUsed.u256 * priorityFeePerGas.u256

  vmState.ledger.addBalance(payer.value, payerRefund, checkEmptyAccount = false)
  vmState.ledger.addBalance(vmState.coinbase, transactionFee, checkEmptyAccount = false)

proc processFrameTransaction(params: CallParams): Result[void, string] =
  let
    vmState = params.vmState
  #tx_env = check_frame_transaction(block_env, block_output, tx, index)

  let
    txOutput = ? processFrames(vmState)
    # `processFrames` invalidates the transaction unless a frame
    # approved payment.
    payer = vmState.payer()

  doAssert payer.isSome

  let
    txUnusedGas = txOutput.gasLeft + txOutput.stateGasLeft
    settlement = settleFrameTransactionGas(
      vmState.frameCtx.standardGasLimit,
      params.intrinsic.floorDataGas,
      txUnusedGas,
      vmState.refundCounter.GasInt,
      txOutput.stateGasUsed
    )

  disburseFrameGasFees(vmState, settlement.gasUsed)

#[
  block_output.block_gas_used += settlement.execution_gas_used
  block_output.block_state_gas_used += settlement.state_gas_used
  block_output.blob_gas_used += calculate_total_blob_gas(tx)

  block_output.cumulative_gas_used += settlement.gas_used

  block_output.block_logs += tx_output.logs

  for address in tx_output.accounts_to_delete:
    clear_account_preserving_balance(tx_env.state, address)

  incorporate_tx_into_block(
    tx_env.state, block_env.block_access_list_builder
  )
]#
#? beginFrameProcessing(params)