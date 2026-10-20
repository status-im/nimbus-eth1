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
from ../core/keyed_nonces import checkNonceSet

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
    accessGas = ledger.gasAccountCheck(delegateTo)

  ? gasMeter.consumeGas(accessGas, "resolveDelegatedCodeAddress")
  msg.flags.incl MsgFlags.Delegated
  msg.delegateTo = delegateTo

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(delegateTo)
  ok(vmState.readOnlyLedger.getCode(delegateTo))

proc createEVMFromFrame(vmState: BaseVMState,
                        frame: TransactionFrame,
                        gasMeter: var GasMeter,
                        resolvedTarget: Address): EvmResult[Computation] =
  let
    ledger = vmState.ledger

  if frame.value.isZero.not and not ledger.isAccountAlive(resolvedTarget):
    ? vmState.chargeFrameStateGas(CREATE_ACCOUNT_STATE_GAS, "create EVM from frame")

  let
    isStaticFrame = frame.mode == VERIFY_MODE or frame.mode == POST_TX_MODE
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
      flags:             if isStaticFrame: {MsgFlags.Static}
                         else: {}
    )
    code = ? resolveDelegatedCodeAddress(vmState, msg, gasMeter)
    evm = newComputation(vmState, false, msg, gasMeter, code)

  vmState.captureStart(evm, vmState.txCtx.origin, resolvedTarget,
                       false, frame.data,
                       frame.gasLimit, frame.value)
  ok(evm)

proc executeFrame(vmState: BaseVMState,
                  frame: TransactionFrame): int64 =
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
    return

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(resolvedTarget)

  if frame.mode == VERIFY_MODE and
     not isPrecompile(vmState.fork, resolvedTarget) and
     ledger.getCodeHash(resolvedTarget) == EMPTY_CODE_HASH:

    let
      status = executeDefaultVerifyCode(vmState, frame, resolvedTarget).valueOr:
        vmState.restoreFrameContext(entrySnapshot)
        vmState.frameOutcomeFailure(executionBudget)
        return

    vmState.frameOutcome(status,
      executionBudget - gasMeter.executionGasLeft,
      stateBudget - vmState.frameStateGasLeft,
    )
    return

  if frame.value.isZero.not:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(vmState.txCtx.origin)
    let
      callerBalance = ledger.getBalance(vmState.txCtx.origin)
    if callerBalance < frame.value:
      vmState.frameOutcomeFailure(executionBudget - gasMeter.executionGasLeft)
      return

  let
    evm = createEVMFromFrame(vmState, frame, gasMeter, resolvedTarget).valueOr:
      vmState.restoreFrameContext(entrySnapshot)
      vmState.frameOutcomeFailure(executionBudget)
      return

  # Frame Transaction only execute `call`, not `create`
  execCallOrCreate(evm)

  if evm.isError:
    # The frame failed: `process_call` rolled its state gas back
    # to the call, and this restore extends the rollback over the
    # frame-entry charge.
    vmState.restoreFrameContext(entrySnapshot)
    if frame.mode == VERIFY_MODE:
      vmState.frameCtx.error = move(evm.error.info)

  if evm.shouldBurnGas:
    evm.gasMeter.burnGas()

  let
    executionGasUsed = executionBudget - evm.gasMeter.executionGasLeft
    stateGasUsed = stateBudget - vmState.frameStateGasLeft

  evm.vmState.captureEnd(evm, evm.output, executionGasUsed, evm.errorOpt)

  if evm.isSuccess:
    vmState.frameOutcomeSuccess(executionGasUsed, stateGasUsed, evm.logEntries)
    evm.gasMeter.refundCounter
  else:
    vmState.frameOutcomeFailure(executionGasUsed, stateGasUsed)
    evm.dispose()
    0

type
  AtomicBatch = object
    firstFrameIndex: int
    stateSnapshot  : LedgerSpRef
    frameSnapshot  : FrameSnapshotRef
    refundCounter  : int64

  TransactionOutput = object
    gasLeft     : GasInt
    stateGasLeft: GasInt
    stateGasUsed: GasInt

  ValidationPrefixCheckpoint = AtomicBatch

template unrollBatch(vmState: BaseVMState, batch: var AtomicBatch) =
  let
    snapshot = vmState.frameCtx.snapshot

  if vmState.balTrackerEnabled:
    vmState.balTracker.rollbackCallFrame()
  vmState.ledger.rollback(batch.stateSnapshot)
  vmState.restoreFrameContext(batch.frameSnapshot)
  vmState.refundCounter = batch.refundCounter

  # Logs emptied and state gas zeroed.
  # Frame consumed gas remains charged.
  for i in 0..<batch.firstFrameIndex:
    snapshot.receipts[i] = move vmState.frameCtx.snapshot.receipts[i]

  for i in batch.firstFrameIndex..<snapshot.receipts.len:
    snapshot.receipts[i].stateGasUsed = 0
    snapshot.receipts[i].logs.setLen(0)

  vmState.frameCtx.snapshot.receipts = move(snapshot.receipts)

  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc unrollAtomicBatch(vmState: BaseVMState, batch: var AtomicBatch) =
  # Static validity bans approval scopes on batch frames, so the
  # unroll can never move the approval context.
  doAssert vmState.payer == batch.frameSnapshot.payer
  doAssert vmState.senderApproved == batch.frameSnapshot.senderApproved
  unrollBatch(vmState, batch)

proc commitAtomicBatch(vmState: BaseVMState, batch: var AtomicBatch) =
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()
  vmState.ledger.commit(batch.stateSnapshot)
  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc revertExecutionBody(vmState: BaseVMState, batch: var ValidationPrefixCheckpoint) =
  # The prefix set the payer, and no later frame can withdraw it.
  doAssert vmState.payer == batch.frameSnapshot.payer
  unrollBatch(vmState, batch)

proc commitValidationPrefixCheckpoint(vmState: BaseVMState, batch: var ValidationPrefixCheckpoint) =
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()
  vmState.ledger.commit(batch.stateSnapshot)
  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc rollbackOnError(vmState: BaseVMState, batch: var AtomicBatch) =
  if vmState.balTrackerEnabled:
    vmState.balTracker.rollbackCallFrame()
  vmState.ledger.rollback(batch.stateSnapshot)
  batch.stateSnapshot = nil
  batch.frameSnapshot = nil

proc processFrames(vmState: BaseVMState): Result[TransactionOutput, string] =
  let
    tx = vmState.getTransaction()
    ledger = vmState.ledger

  vmState.txLogs.setLen(0)
  ledger.accessList(tx.sender)

  var
    openBatch = Opt.none(AtomicBatch)
    skipBatch = false
    prefixCheckpoint = Opt.none(ValidationPrefixCheckpoint)
    loopError: string

  template breakLoopErr(msg: string) =
    loopError = msg
    break

  for index, frame in tx.frames:
    vmState.frameCtx.snapshot.currentFrameIndex = index
    let
      hasBatchFlag = (frame.flags and ATOMIC_BATCH_FLAG) != 0

    if hasBatchFlag and openBatch.isNone:
      if vmState.balTrackerEnabled:
        vmState.balTracker.beginCallFrame()
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
      breakLoopErr("SENDER frame before execution approval")

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
      refundCounter = executeFrame(vmState, frame)
      receipt = vmState.latestFrameReceipt()

    if receipt.status == FRAME_STATUS_FAILURE:
      ledger.restoreAccessList(accessListSnapshot)
      ledger.restoreSelfDestruct(selfDestructSnapshot)
      if frame.mode == VERIFY_MODE:
        breakLoopErr("VERIFY frame failed: " & vmState.frameCtx.error)

    vmState.refundCounter += refundCounter

    if frame.mode == POST_TX_MODE and receipt.status == FRAME_STATUS_FAILURE:
      # The assertion failed: the execution body is reverted
      # unconditionally, overriding any atomic batch. Without a
      # validation prefix there is no body to revert, and the
      # transaction is invalid after the loop regardless.
      if prefixCheckpoint.isSome:
        vmState.revertExecutionBody(prefixCheckpoint.value)
        prefixCheckpoint = Opt.none(ValidationPrefixCheckpoint)

      # The remaining frames never execute. Their zero-usage
      # receipts make their allotted gas count as unused.
      let snapshot = vmState.frameCtx.snapshot
      for _ in index+1..<tx.frames.len:
        snapshot.receipts.add FrameReceipt(status: FRAME_STATUS_SKIPPED)
      break

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

    if prefixCheckpoint.isNone and vmState.payer.isSome:
      # The validation prefix ended with this frame: checkpoint
      # the state a failing `POST_TX_MODE` frame restores to.
      # `validateTxEip8141` bans approval scope on batch
      # frames, so no batch is open.
      doAssert openBatch.isNone
      if vmState.balTrackerEnabled:
        vmState.balTracker.beginCallFrame()
      prefixCheckpoint = Opt.some(ValidationPrefixCheckpoint(
        firstFrameIndex: index + 1,
        stateSnapshot  : ledger.beginSavePoint(),
        frameSnapshot  : vmState.copyFrameContext(),
        refundCounter  : vmState.refundCounter,
      ))

  if loopError.len > 0:
    if openBatch.isSome:
      vmState.rollbackOnError(openBatch.value)

    if prefixCheckpoint.isSome:
      vmState.rollbackOnError(prefixCheckpoint.value)

    return err(move loopError)

  if prefixCheckpoint.isSome:
    vmState.commitValidationPrefixCheckpoint(prefixCheckpoint.value)
    prefixCheckpoint = Opt.none(ValidationPrefixCheckpoint)

  if vmState.payer.isNone:
    return err("no frame approved gas payment")

  for receipt in vmState.frameCtx.snapshot.receipts:
    vmState.txLogs.add receipt.logs

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
  GasSettlement* = object
    gasUsed*         : GasInt
    executionGasUsed*: GasInt
    stateGasUsed*    : GasInt

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

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddBalanceChange(payer.value, payerRefund)
  vmState.ledger.addBalance(payer.value, payerRefund, checkEmptyAccount = false)

proc prepareFrameProcessing(params: CallParams): Result[void, string] =
  let
    sigHash = computeSigHash(params.tx[])
    vmState = params.vmState
    tx = params.tx
    fork = vmState.hardFork

  vmState.txCtx = TxContext(
    origin            : params.sender,
    effectiveGasPrice : params.effectiveGasPrice,
    blobBaseFee       : getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
    tx                : params.tx,
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.refundCounter = 0

  vmState.enableFrame()
  vmState.frameCtx.txDiff = nil

  var
    totalFrameGas = 0.GasInt
    totalFrameExecutionGas = 0.GasInt
    totalFrameStateGas = 0.GasInt

  for frame in tx.frames:
    totalFrameExecutionGas += frame.gasLimit
    totalFrameStateGas += frame.stateGasLimit
    totalFrameGas += frame.gasLimit + frame.stateGasLimit

  vmState.frameCtx.standardGasLimit = params.intrinsic.execution + totalFrameGas

  let
    maxGas = max(
      vmState.frameCtx.standardGasLimit,
      params.intrinsic.floorDataGas + totalFrameStateGas
    )

  vmState.frameCtx.maxCost = maxGas.u256 * tx.maxFeePerGas.u256 + vmState.blobGasFee

  vmState.frameCtx.resolvedSigners.setLen(tx.signatures.len)
  for i, sig in tx.signatures:
    let address = ? validateSignature(sig, tx.sender, sigHash)
    vmState.frameCtx.resolvedSigners[i] = address

  vmState.frameCtx.signatureHash = sigHash

  ? checkNonceSet(vmState, tx[])
  vmState.frameCtx.legacyNonce = vmState.readOnlyLedger.getNonce(tx.sender)

  ok()

proc processFrameTransaction*(params: CallParams): Result[GasSettlement, string] =
  ? prepareFrameProcessing(params)

  let
    vmState = params.vmState
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

  ok(settlement)
