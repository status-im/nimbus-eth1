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
  ../../../transaction/call_types,
  ../../../core/eip8141,
  ../../../db/ledger,
  ../../computation,
  ../../evm_errors,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../op_codes,
  ./oph_defs

from ../../../core/eip8037 import CREATE_ACCOUNT_STATE_GAS

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
    reason = "RETURN")

  let
    tx = cpt.getTransaction()

  if tx.isNil or tx.txType != TxEip8141:
    return err(opErr(EvmInvalidParam))

  let
    frameIndex = cpt.getCurrentFrameIndex()
    frame = cpt.getFrame(frameIndex)
    resolvedTarget = cpt.resolveFrameTarget(frame)

  # Only the frame's resolved target may approve.
  if cpt.msg.contractAddress != resolvedTarget:
    cpt.setError(StatusCode.Revert, "Approve: Invalid resolved target", false)
    return ok()

  # A scope with bits beyond the approval mask is never allowed.
  if (scope and not APPROVE_SCOPE_MASK) != 0:
    cpt.setError(StatusCode.Revert, "Approve: Invalid scope bits", false)
    return ok()

  let attemptAprroval = ? cpt.vmState.attemptApproval(scope, resolvedTarget)
  if not attemptAprroval:
    cpt.setError(StatusCode.Revert, "Approve: Attempt to approve failed", false)
    return ok()

  cpt.memory.extend(pos, len)
  assign(cpt.output, cpt.memory.read(pos, len))
  ok()

func txParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb0, Gives access to transaction-scoped information.
  ? cpt.stack.lsCheck(1)
  let
    param = cpt.stack.lsPeekMemRef(^1)
    tx = cpt.getTransaction()

  if tx.isNil:
    cpt.stack.lsTop 0
    return ok()

  var value {.noinit.}: UInt256
  case param
  of 0:
    value = tx.txType.uint.u256
  of 1:
    value = tx.nonce.u256
  of 2:
    value.initFromBytesBE(tx.sender.data)
  of 3:
    value = tx.maxPriorityFeePerGas.u256
  of 4:
    value = tx.maxFeePerGas.u256
  of 5:
    value = tx.maxFeePerBlobGas
  of 6:
    value = cpt.getMaxCost().u256
  of 7:
    value = tx.versionedHashes.len.u256
  of 8:
    let sigHash = computeSigHash(tx[])
    value.initFromBytesBE(sigHash.data)
  of 9:
    value = tx.frames.len.u256
  of 10:
    value = cpt.getCurrentFrameIndex().u256
  of 11:
    value = tx.signatures.len.u256
  of 12:
    value =  cpt.gasMeter.stateGasLeft.u256
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
  cpt.stack.lsShrink(1)

  if frameIndex >= cpt.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let frame = cpt.getFrame(frameIndex)
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

  if frameIndex >= cpt.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let frame = cpt.getFrame(frameIndex)

  cpt.memory.writePadded(frame.data, memPos, dataPos, len)
  ok()

func frameParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb3, Gives access to frame-scoped information.
  ? cpt.stack.lsCheck(2)
  let
    frameIndex = cpt.stack.lsPeekMemRef(^1)
    param = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(1)

  if frameIndex >= cpt.getFramesLen:
    return err(opErr(EvmInvalidParam))

  let frame = cpt.getFrame(frameIndex)
  var value {.noinit.}: UInt256
  case param
  of 0:
    value.initFromBytesBE cpt.resolveFrameTarget(frame).data
  of 1:
    value = frame.gasLimit.u256
  of 2:
    value = frame.mode.u256
  of 3:
    value = frame.flags.u256
  of 4:
    value = frame.data.len.u256
  of 5:
    if frameIndex >= cpt.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = cpt.getFrameStatus(frameIndex).uint.u256
  of 6:
    value = (frame.flags and APPROVE_SCOPE_MASK).u256
  of 7:
    if (frame.flags and ATOMIC_BATCH) != 0:
      value = 1.u256
    else:
      value = 0.u256
  of 8:
    value = frame.value
  of 9:
    value = frame.stateGasLimit.u256
  of 10:
    if frameIndex >= cpt.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = cpt.getFrameGasUsed(frameIndex).u256
  of 11:
    if frameIndex >= cpt.getCurrentFrameIndex:
      return err(opErr(EvmInvalidParam))
    value = cpt.getFrameStateGasUsed(frameIndex).u256
  else:
    return err(opErr(EvmInvalidParam))

  cpt.stack.lsTop value
  ok()

func sigParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb4, Gives access to signature-scoped metadata.
  ? cpt.stack.lsCheck(2)
  let
    sigIndex = cpt.stack.lsPeekMemRef(^1)
    param = cpt.stack.lsPeekMemRef(^2)
  cpt.stack.lsShrink(1)

  if sigIndex >= cpt.getSignaturesLen:
    return err(opErr(EvmInvalidParam))

  let sig = cpt.getSignature(sigIndex)
  var value {.noinit.}: UInt256
  case param
  of 0:
    if sig.scheme == SCHEME_ARBITRARY:
      return err(opErr(EvmInvalidParam))
    value.initFromBytesBE(cpt.getResolvedSigner(sigIndex).data)
  of 1:
    value = sig.scheme.u256
  of 2:
    if sig.msg.len == 0:
      value = 0.u256
    else:
      value.initFromBytesBE(sig.msg)
  of 3:
    if sig.scheme == SCHEME_ARBITRARY:
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

  if sigIndex >= cpt.getSignaturesLen:
    return err(opErr(EvmInvalidParam))

  let sig = cpt.getSignature(sigIndex)
  if sig.scheme != SCHEME_ARBITRARY:
    return err(opErr(EvmInvalidParam))

  cpt.memory.writePadded(sig.signature, memPos, dataPos, len)
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
     exec: sigDataCopyOp)]
