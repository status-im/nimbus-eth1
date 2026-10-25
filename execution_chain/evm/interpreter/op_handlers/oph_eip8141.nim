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
  stew/assign2,
  ../../../db/ledger,
  ../../computation,
  ../../evm_errors,
  ../../stack,
  ../../state,
  ../../types,
  ../gas_costs,
  ../op_codes,
  ./oph_defs

from ../../../transaction/call_types import SCHEME_ARBITRARY

from ../../../core/eip8141 import
  resolveFrameTarget,
  ASSERT_MODE,
  APPROVE_SCOPE_MASK,
  ATOMIC_BATCH_FLAG,
  attemptApproval

from ../../../core/keyed_nonces import
  nonceKeysHash,
  nonceSeq

proc approveOp(cpt: VmCpt): EvmResultVoid =
  ## 0xaa, Exits current EVM call frame successfully.
  ? cpt.stack.lsCheck(3)
  let
    pos = cpt.stack.lsPeekMemRef(^1)
    len = cpt.stack.lsPeekMemRef(^2)
    scope = cpt.stack.lsPeekMemRef(^3)
  cpt.stack.lsShrink(3)

  ? cpt.opcodeGasCost(Approve,
    cpt.gasCosts[Approve].m_handler(cpt.memory.len, pos, len),
    reason = "Approve")

  let
    vmState = cpt.vmState
    tx = vmState.getTransaction()

  if not vmState.frameEnabled:
    return err(opErr(EvmInvalidParam))

  let
    frameIndex = vmState.getCurrentFrameIndex()
    frame = vmState.getFrame(frameIndex)
    resolvedTarget = tx.resolveFrameTarget(frame)

  if frame.mode == ASSERT_MODE:
    return err(opErr(StaticContext))

  # Only the frame's resolved target may approve.
  if cpt.msg.currentTarget != resolvedTarget:
    cpt.setError(StatusCode.Revert, "Approve: Invalid resolved target", false)
    return ok()

  # A scope with bits beyond the approval mask is never allowed.
  if (scope and not APPROVE_SCOPE_MASK) != 0:
    cpt.setError(StatusCode.Revert, "Approve: Invalid scope bits", false)
    return ok()

  let attemptAprroval = ? vmState.attemptApproval(frame[], scope.uint, resolvedTarget)
  if not attemptAprroval:
    cpt.setError(StatusCode.Revert, "Approve: Attempt to approve failed", false)
    return ok()

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))
  ok()

const
  TXPARAM_TYPE = 0x00
  TXPARAM_NONCE_SEQ = 0x01
  TXPARAM_SENDER = 0x02
  TXPARAM_MAX_PRIORITY_FEE_PER_GAS = 0x03
  TXPARAM_MAX_FEE_PER_GAS = 0x04
  TXPARAM_MAX_FEE_PER_BLOB_GAS = 0x05
  TXPARAM_MAX_COST = 0x06
  TXPARAM_BLOB_COUNT = 0x07
  TXPARAM_SIG_HASH = 0x08
  TXPARAM_FRAME_COUNT = 0x09
  TXPARAM_CURRENT_FRAME_INDEX = 0x0A
  TXPARAM_SIGNATURE_COUNT = 0x0B
  TXPARAM_STATE_GAS_LEFT = 0x0C
  TXPARAM_LEGACY_NONCE = 0x0D
  TXPARAM_NONCE_KEYS_COUNT = 0x0E
  TXPARAM_NONCE_KEYS_HASH = 0x0F
  TXPARAM_FIRST_NONCE_KEY = 0x10

func txParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb0, Gives access to transaction-scoped information.
  ? cpt.stack.lsCheck(1)
  let
    param = cpt.stack.lsPeekMemRef(^1)
    vmState = cpt.vmState
    tx = vmState.getTransaction()

  if not vmState.frameEnabled:
    return err(opErr(EvmInvalidParam))

  var value {.noinit.}: UInt256
  case param
  of TXPARAM_TYPE:
    value = tx.txType.uint.u256
  of TXPARAM_NONCE_SEQ:
    value = tx.nonceSeq.u256
  of TXPARAM_SENDER:
    value.initFromBytesBE(tx.sender.data)
  of TXPARAM_MAX_PRIORITY_FEE_PER_GAS:
    value = tx.maxPriorityFeePerGas.u256
  of TXPARAM_MAX_FEE_PER_GAS:
    value = tx.maxFeePerGas.u256
  of TXPARAM_MAX_FEE_PER_BLOB_GAS:
    value = tx.maxFeePerBlobGas
  of TXPARAM_MAX_COST:
    value = vmState.getMaxCost()
  of TXPARAM_BLOB_COUNT:
    value = tx.versionedHashes.len.u256
  of TXPARAM_SIG_HASH:
    value.initFromBytesBE(vmState.frameCtx.signatureHash.data)
  of TXPARAM_FRAME_COUNT:
    value = tx.frames.len.u256
  of TXPARAM_CURRENT_FRAME_INDEX:
    value = vmState.getCurrentFrameIndex().u256
  of TXPARAM_SIGNATURE_COUNT:
    value = tx.signatures.len.u256
  of TXPARAM_STATE_GAS_LEFT:
    value = vmState.frameStateGasLeft().u256
  of TXPARAM_LEGACY_NONCE:
    value = vmState.getLegacyNonce().u256
  of TXPARAM_NONCE_KEYS_COUNT:
    value = tx.nonceKeys.len.u256
  of TXPARAM_NONCE_KEYS_HASH:
    value.initFromBytesBE(nonceKeysHash(tx[]).data)
  of TXPARAM_FIRST_NONCE_KEY:
    value = tx.nonceKeys[0]
  else:
    return err(opErr(EvmInvalidParam))

  cpt.stack.lsTop value
  ok()

func frameDataLoadOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb1, Loads one 32-byte word of data from frame input.
  ? cpt.stack.lsCheck(2)
  let
    start = cpt.stack.lsPeekMemRef(^1)
    frameIndex = cpt.stack.lsPeekMemRef(^2)
    vmState = cpt.vmState
  cpt.stack.lsShrink(1)

  if frameIndex >= vmState.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let
    frame = vmState.getFrame(frameIndex)

  if start >= frame.data.len:
    cpt.stack.lsTop 0
    return ok()

  # If the data does not take 32 bytes, pad with zeros
  let
    endRange = min(frame.data.len - 1, start + 31)
    presentBytes = endRange - start

  # We rely on value being initialized with 0 by default
  var value: array[32, byte]
  assign(value.toOpenArray(0, presentBytes), frame.data.toOpenArray(start, endRange))
  cpt.stack.lsTop value
  ok()

proc frameDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb2, Copies data frame input into the contract’s memory.
  ? cpt.stack.lsCheck(4)
  let
    memPos     = cpt.stack.lsPeekMemRef(^1)
    dataPos    = cpt.stack.lsPeekMemRef(^2)
    len        = cpt.stack.lsPeekMemRef(^3)
    frameIndex = cpt.stack.lsPeekMemRef(^4)
  cpt.stack.lsShrink(4)

  ? cpt.opcodeGasCost(FrameDataCopy,
    cpt.gasCosts[FrameDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "FrameDataCopy fee")

  let vmState = cpt.vmState
  if frameIndex >= vmState.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let frame = vmState.getFrame(frameIndex)

  cpt.memory.writePadded(frame.data, memPos, dataPos, len)
  ok()

const
  FRAMEPARAM_RESOLVED_TARGET = 0x00
  FRAMEPARAM_EXECUTION_GAS_LIMIT = 0x01
  FRAMEPARAM_MODE = 0x02
  FRAMEPARAM_FLAGS = 0x03
  FRAMEPARAM_DATA_LENGTH = 0x04
  FRAMEPARAM_STATUS = 0x05
  FRAMEPARAM_ALLOWED_SCOPE = 0x06
  FRAMEPARAM_ATOMIC_BATCH = 0x07
  FRAMEPARAM_VALUE = 0x08
  FRAMEPARAM_STATE_GAS_LIMIT = 0x09
  FRAMEPARAM_EXECUTION_GAS_USED = 0x0A
  FRAMEPARAM_STATE_GAS_USED = 0x0B

func frameParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb3, Gives access to frame-scoped information.
  ? cpt.stack.lsCheck(2)
  let
    frameIndex = cpt.stack.lsPeekMemRef(^1)
    param = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(1)

  let vmState = cpt.vmState
  if frameIndex >= vmState.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let frame = vmState.getFrame(frameIndex)
  var value {.noinit.}: UInt256
  case param
  of FRAMEPARAM_RESOLVED_TARGET:
    let tx = vmState.getTransaction()
    value.initFromBytesBE tx.resolveFrameTarget(frame).data
  of FRAMEPARAM_EXECUTION_GAS_LIMIT:
    value = frame.gasLimit.u256
  of FRAMEPARAM_MODE:
    value = frame.mode.u256
  of FRAMEPARAM_FLAGS:
    value = frame.flags.u256
  of FRAMEPARAM_DATA_LENGTH:
    value = frame.data.len.u256
  of FRAMEPARAM_STATUS:
    if frameIndex >= vmState.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = vmState.getFrameStatus(frameIndex).uint.u256
  of FRAMEPARAM_ALLOWED_SCOPE:
    value = (frame.flags and APPROVE_SCOPE_MASK).u256
  of FRAMEPARAM_ATOMIC_BATCH:
    if (frame.flags and ATOMIC_BATCH_FLAG) != 0:
      value = 1.u256
    else:
      value = 0.u256
  of FRAMEPARAM_VALUE:
    value = frame.value
  of FRAMEPARAM_STATE_GAS_LIMIT:
    value = frame.stateGasLimit.u256
  of FRAMEPARAM_EXECUTION_GAS_USED:
    if frameIndex >= vmState.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = vmState.getFrameGasUsed(frameIndex).u256
  of FRAMEPARAM_STATE_GAS_USED:
    if frameIndex >= vmState.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = vmState.getFrameStateGasUsed(frameIndex).u256
  else:
    return err(opErr(EvmInvalidParam))

  cpt.stack.lsTop value
  ok()

const
  SIGPARAM_RESOLVED_SIGNER = 0x00
  SIGPARAM_SCHEME = 0x01
  SIGPARAM_MSG = 0x02
  SIGPARAM_SIGNATURE_LENGTH = 0x03

func sigParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb4, Gives access to signature-scoped metadata.
  ? cpt.stack.lsCheck(2)
  let
    sigIndex = cpt.stack.lsPeekMemRef(^1)
    param = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(1)

  let vmState = cpt.vmState
  if sigIndex >= vmState.getSignaturesLen:
    return err(opErr(EvmInvalidParam))

  let sig = vmState.getSignature(sigIndex)
  var value {.noinit.}: UInt256
  case param
  of SIGPARAM_RESOLVED_SIGNER:
    if sig.scheme == SCHEME_ARBITRARY:
      # To simplify implementation, check for the scheme instead
      # of using Opt[Address] for resolvedSigner
      return err(opErr(EvmInvalidParam))
    value.initFromBytesBE(vmState.getResolvedSigner(sigIndex).data)
  of SIGPARAM_SCHEME:
    value = sig.scheme.u256
  of SIGPARAM_MSG:
    if sig.msg.len == 0:
      value = 0.u256
    else:
      value.initFromBytesBE(sig.msg)
  of SIGPARAM_SIGNATURE_LENGTH:
    if sig.scheme != SCHEME_ARBITRARY:
      return err(opErr(EvmInvalidParam))
    value = sig.signature.len.u256
  else:
    return err(opErr(EvmInvalidParam))

  cpt.stack.lsTop value
  ok()

proc sigDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb5, Copies a signature’s raw signature bytes into the contract’s memory.
  ? cpt.stack.lsCheck(4)
  let
    memPos   = cpt.stack.lsPeekMemRef(^1)
    dataPos  = cpt.stack.lsPeekMemRef(^2)
    len      = cpt.stack.lsPeekMemRef(^3)
    sigIndex = cpt.stack.lsPeekMemRef(^4)
  cpt.stack.lsShrink(4)

  ? cpt.opcodeGasCost(SigDataCopy,
    cpt.gasCosts[SigDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "SigDataCopy fee")

  let vmState = cpt.vmState
  if sigIndex >= vmState.getSignaturesLen:
    return err(opErr(EvmInvalidParam))

  let sig = vmState.getSignature(sigIndex)
  if sig.scheme != SCHEME_ARBITRARY:
    return err(opErr(EvmInvalidParam))

  cpt.memory.writePadded(sig.signature, memPos, dataPos, len)
  ok()

func assertFrameSnapshot(vmState: BaseVMState): EvmResult[FrameSnapshotRef] =
  ## Return the executing frame transaction's context, or exceptionally
  ## halt unless the executing frame is a `POST_TX` frame.
  ##
  ## The check keys on the frame, not the call depth, so the diff
  ## instructions are valid anywhere in a `POST_TX` frame's call subtree
  ## and nowhere else.
  if not vmState.frameEnabled:
    return err(opErr(EvmInvalidParam))

  let
    snapshot = vmState.frameCtx.snapshot
    frame = vmState.getFrame(snapshot.currentFrameIndex)

  if frame.mode != ASSERT_MODE:
    return err(opErr(EvmInvalidParam))

  ok(snapshot)

func requireReservedZero(operand: int): EvmResultVoid =
  ## Exceptionally halt unless an operand the parameter tables mark
  ## *must be 0* is zero.
  if operand != 0:
    return err(opErr(EvmInvalidParam))
  ok()

const
  TRACE_BALANCES_CHANGED = 0x00
  TRACE_SLOTS_CHANGED = 0x01
  TRACE_CODES_CHANGED = 0x02
  TRACE_NONCES_CHANGED = 0x03
  TRACE_BALANCE_ADDRESS = 0x04
  TRACE_BALANCE_BEFORE = 0x05
  TRACE_BALANCE_AFTER = 0x06
  TRACE_SLOT_ADDRESS = 0x07
  TRACE_SLOT_BEFORE = 0x08
  TRACE_SLOT_AFTER = 0x09
  TRACE_SLOT_KEY = 0x0A
  TRACE_CODE_ADDRESS = 0x0B
  TRACE_CODE_BEFORE = 0x0C
  TRACE_CODE_AFTER = 0x0D
  TRACE_NONCE_ADDRESS = 0x0E
  TRACE_NONCE_BEFORE = 0x0F
  TRACE_NONCE_AFTER = 0x10
  TRACE_EVENTS_COUNT = 0x11
  TRACE_EVENT_ADDRESS = 0x12
  TRACE_EVENT_TOPIC_COUNT = 0x13
  TRACE_EVENT_TOPIC_0 = 0x14
  TRACE_EVENT_TOPIC_1 = 0x15
  TRACE_EVENT_TOPIC_2 = 0x16
  TRACE_EVENT_TOPIC_3 = 0x17
  TRACE_EVENT_DATA_LEN = 0x18
  TRACE_GAS_PRE_CHARGE = 0x19
  TRACE_GAS_PAYER = 0x1A

proc txTraceOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb6, Reads the state diff of the current transaction.
  ? cpt.stack.lsCheck(2)
  let
    param = cpt.stack.lsPeekMemRef(^1)
    index = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(1)
  var value {.noinit.}: UInt256

  let
    frameSnapshot = ? assertFrameSnapshot(cpt.vmState)
    diff = cpt.vmState.transactionDiff(frameSnapshot)

  case param
  of TRACE_BALANCES_CHANGED:
    ? requireReservedZero(index)
    value = diff.balances.len.u256
  of TRACE_SLOTS_CHANGED:
    ? requireReservedZero(index)
    value = diff.slots.len.u256
  of TRACE_CODES_CHANGED:
    ? requireReservedZero(index)
    value = diff.codes.len.u256
  of TRACE_NONCES_CHANGED:
    ? requireReservedZero(index)
    value = diff.nonces.len.u256
  of TRACE_BALANCE_ADDRESS:
    value = ? diff.balanceAddress(index)
  of TRACE_BALANCE_BEFORE:
    ? tableEntry(diff.balances, index)
    value = diff.balances[index].before
  of TRACE_BALANCE_AFTER:
    ? tableEntry(diff.balances, index)
    value = diff.balances[index].after
  of TRACE_SLOT_ADDRESS:
    value = ? diff.slotAddress(index)
  of TRACE_SLOT_BEFORE:
    ? tableEntry(diff.slots, index)
    value = diff.slots[index].before
  of TRACE_SLOT_AFTER:
    ? tableEntry(diff.slots, index)
    value = diff.slots[index].after
  of TRACE_SLOT_KEY:
    ? tableEntry(diff.slots, index)
    value = diff.slots[index].key
  of TRACE_CODE_ADDRESS:
    value = ? diff.codeAddress(index)
  of TRACE_CODE_BEFORE:
    value = ? diff.codeBefore(index)
  of TRACE_CODE_AFTER:
    value = ? diff.codeAfter(index)
  of TRACE_NONCE_ADDRESS:
    value = ? diff.nonceAddress(index)
  of TRACE_NONCE_BEFORE:
    ? tableEntry(diff.nonces, index)
    value = diff.nonces[index].before.u256
  of TRACE_NONCE_AFTER:
    ? tableEntry(diff.nonces, index)
    value = diff.nonces[index].after.u256
  of TRACE_EVENTS_COUNT:
    ? requireReservedZero(index)
    value = diff.events.len.u256
  of TRACE_EVENT_ADDRESS:
    value = ? diff.eventAddress(index)
  of TRACE_EVENT_TOPIC_COUNT:
    value = ? diff.eventTopicsCount(index)
  of TRACE_EVENT_TOPIC_0:
    value = ? diff.eventTopic(index, 0)
  of TRACE_EVENT_TOPIC_1:
    value = ? diff.eventTopic(index, 1)
  of TRACE_EVENT_TOPIC_2:
    value = ? diff.eventTopic(index, 2)
  of TRACE_EVENT_TOPIC_3:
    value = ? diff.eventTopic(index, 3)
  of TRACE_EVENT_DATA_LEN:
    value = ? diff.eventDataLen(index)
  of TRACE_GAS_PRE_CHARGE:
    ? requireReservedZero(index)
    value = cpt.vmState.getMaxCost()
  of TRACE_GAS_PAYER:
    ? requireReservedZero(index)
    if cpt.vmState.payer.isNone:
      value = 0.u256
    else:
      let payer = cpt.vmState.payer.value
      value.initFromBytesBE(payer.data)
  else:
    return err(opErr(EvmInvalidParam))

  cpt.stack.lsTop value
  ok()

proc eventDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0xB7, Copies event data to memory.
  ? cpt.stack.lsCheck(4)
  let
    eventIndex = cpt.stack.lsPeekMemRef(^1)
    memPos     = cpt.stack.lsPeekMemRef(^2)
    dataPos    = cpt.stack.lsPeekMemRef(^3)
    len        = cpt.stack.lsPeekMemRef(^4)
  cpt.stack.lsShrink(4)

  ? cpt.opcodeGasCost(EventDataCopy,
    cpt.gasCosts[SigDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "EventDataCopy fee")

  let
    frameSnapshot = ? assertFrameSnapshot(cpt.vmState)
    diff = cpt.vmState.transactionDiff(frameSnapshot)

  ? tableEntry(diff.events, eventIndex)
  if dataPos + len > diff.events[eventIndex].data.len:
    return err(opErr(EvmInvalidParam))

  cpt.memory.writePadded(diff.events[eventIndex].data, memPos, dataPos, len)
  ok()

const
  VmOpExecEIP8141*: seq[VmOpExec] = @[
    (opCode: Approve,       ## 0xaa, Exits current EVM call frame successfully.
     forks: VmOpBogotaAndLater,
     name: "Approve",
     info: "Exits current EVM call frame successfully",
     exec: VmOpFn approveOp),


    (opCode: TxParam,       ## 0xb0, Gives access to transaction-scoped information.
     forks: VmOpBogotaAndLater,
     name: "TxParam",
     info: "Gives access to transaction-scoped information",
     exec: txParamOp),


    (opCode: FrameDataLoad, ## 0xb1, Loads one 32-byte word of data from frame input.
     forks: VmOpBogotaAndLater,
     name: "FrameDataLoad",
     info: "Loads one 32-byte word of data from frame input",
     exec: frameDataLoadOp),


    (opCode: FrameDataCopy, ## 0xb2, Copies data frame input into the contract’s memory.
     forks: VmOpBogotaAndLater,
     name: "FrameDataCopy",
     info: "Copies data frame input into the contract’s memory",
     exec: frameDataCopyOp),


    (opCode: FrameParam,    ## 0xb3, Gives access to frame-scoped information.
     forks: VmOpBogotaAndLater,
     name: "FrameParam",
     info: "Gives access to frame-scoped information",
     exec: frameParamOp),


    (opCode: SigParam,      ## 0xb4, Gives access to signature-scoped metadata.
     forks: VmOpBogotaAndLater,
     name: "SigParam",
     info: "Gives access to signature-scoped metadata",
     exec: sigParamOp),


    (opCode: SigDataCopy,   ## 0xb5, Copies a signature’s raw signature bytes into the contract’s memory.
     forks: VmOpBogotaAndLater,
     name: "SigDataCopy",
     info: "Copies a signature’s raw signature bytes into the contract’s memory",
     exec: sigDataCopyOp),


    (opCode: TxTrace,       ## 0xb6, Reads the state diff of the current transaction.
     forks: VmOpBogotaAndLater,
     name: "TxTrace",
     info: "Reads the state diff of the current transaction",
     exec: txTraceOp),


     (opCode: EventDataCopy,## 0xb7, Copies event data to memory.
     forks: VmOpBogotaAndLater,
     name: "EventDataCopy",
     info: "Copies event data to memory",
     exec: eventDataCopyOp)]
