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
  ../../evm_errors,
  ../../stack,
  ../../types,
  ../../computation,
  ../gas_costs,
  ../op_codes,
  ./oph_defs

func approveOp(cpt: VmCpt): EvmResultVoid =
  ## 0xaa, Exits current EVM call frame successfully.
  discard

func txParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb0, Gives access to transaction-scoped information.
  ? cpt.stack.lsCheck(1)
  let start = cpt.stack.lsPeekMemRef(^1)
  #cpt.stack.lsTop value
  ok()

func frameDataLoadOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb1, Loads one 32-byte word of data from frame input.
  ? cpt.stack.lsCheck(1)
  let start = cpt.stack.lsPeekMemRef(^1)

  if start >= cpt.msg.data.len:
    cpt.stack.lsTop 0
    return ok()

  # If the data does not take 32 bytes, pad with zeros
  let
    endRange = min(cpt.msg.data.len - 1, start + 31)
    presentBytes = endRange - start

  # We rely on value being initialized with 0 by default
  #var value: array[32, byte]
  #assign(value.toOpenArray(0, presentBytes), cpt.msg.data.toOpenArray(start, endRange))
  #cpt.stack.lsTop value
  ok()

proc frameDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb2, Copies data frame input into the contract’s memory.
  ? cpt.stack.lsCheck(4)
  let
    memPos     = cpt.stack.lsPeekMemRef(^1)
    copyPos    = cpt.stack.lsPeekMemRef(^2)
    len        = cpt.stack.lsPeekMemRef(^3)
    frameIndex = cpt.stack.lsPeekMemRef(^4)
  cpt.stack.lsShrink(4)

  ? cpt.opcodeGasCost(FrameDataCopy,
    cpt.gasCosts[FrameDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "FrameDataCopy fee")

  cpt.memory.writePadded(cpt.msg.data, memPos, copyPos, len)
  ok()

func frameParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb3, Gives access to frame-scoped information.
  ? cpt.stack.lsCheck(1)
  let start = cpt.stack.lsPeekMemRef(^1)
  #cpt.stack.lsTop value
  ok()

func sigParamOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb4, Gives access to signature-scoped metadata.
  ? cpt.stack.lsCheck(1)
  let start = cpt.stack.lsPeekMemRef(^1)
  #cpt.stack.lsTop value
  ok()

proc sigDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0xb5, Copies a signature’s raw signature bytes into the contract’s memory.
  ? cpt.stack.lsCheck(4)
  let
    memPos   = cpt.stack.lsPeekMemRef(^1)
    copyPos  = cpt.stack.lsPeekMemRef(^2)
    len      = cpt.stack.lsPeekMemRef(^3)
    sigIndex = cpt.stack.lsPeekMemRef(^4)
  cpt.stack.lsShrink(4)

  ? cpt.opcodeGasCost(SigDataCopy,
    cpt.gasCosts[SigDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "SigDataCopy fee")

  cpt.memory.writePadded(cpt.msg.data, memPos, copyPos, len)
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
