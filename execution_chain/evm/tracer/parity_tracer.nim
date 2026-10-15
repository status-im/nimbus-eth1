# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, hashes, strutils],
  results,
  eth/common/eth_types,
  web3/eth_api_types,
  ".."/[types, stack, memory, computation, precompiles, code_stream],
  ../interpreter/op_codes,
  ../interpreter/utils/utils_numeric,
  ../../db/ledger,
  ../../rpc/trace_types

proc hash*(x: UInt256): Hash =
  hash(x.toBytesBE)

type
  AccountSnap = object
    balance: UInt256
    nonce:   uint64
    code:    seq[byte]
    exists:  bool

  MemReadKind = enum
    mrNone, mrStored, mrWindow

  PendingOp = object
    active:   bool
    op:       Op
    vmOp:     VmTraceOp
    storeKey: UInt256
    storeVal: UInt256
    isStore:  bool
    memKind:  MemReadKind
    memOff:   int
    memLen:   int
    memData:  seq[byte]

  ParityFrame = object
    action:        TraceAction
    actionKind:    TraceActionKind
    traceAddr:     seq[int]
    childIndex:    int
    createAddress: EthAddress
    resultIdx:     int
    skip:          bool
    vmTrace:       VmTrace
    pending:       PendingOp

  ParityTracer* = ref object of TracerRef
    frames:     seq[ParityFrame]
    results*:   seq[TraceObject]
    traceTypes*: set[TraceTypeFlag]
    preState:   Table[EthAddress, AccountSnap]
    preStorage: Table[EthAddress, Table[UInt256, UInt256]]
    stateDiff*: StateDiff
    vmTrace*:   Opt[VmTrace]
    output*:    seq[byte]

proc newParityTracer*(traceTypes: set[TraceTypeFlag] = {TraceTypeFlag.ttTrace}): ParityTracer =
  ParityTracer(traceTypes: traceTypes)

proc callTypeForOp(op: Op): TraceCallType =
  case op
  of CallCode:     callcode
  of DelegateCall: delegatecall
  of StaticCall:   staticcall
  else:            call

func parityError(comp: Computation): Opt[string] =
  if comp.isSuccess:
    return Opt.none(string)
  if comp.error.isNil:
    return Opt.none(string)
  case comp.error.status
  of StatusCode.None:
    Opt.none(string)
  of StatusCode.Revert:
    Opt.some("Reverted")
  of StatusCode.OutOfGas:
    Opt.some("Out of gas")
  of StatusCode.PrecompileFailure:
    Opt.some("Built-in failed")
  of StatusCode.ContractValidationFailure:
    Opt.some("Out of gas")
  of StatusCode.Failure:
    let info = comp.error.info
    if "StaticContext" in info:
      Opt.some("Mutable Call In Static Context")
    elif "InvalidJumpDest" in info:
      Opt.some("Bad jump destination")
    elif "StackInsufficient" in info:
      Opt.some("Stack underflow")
    elif "StackFull" in info:
      Opt.some("Out of stack")
    elif "InvalidInstruction" in info:
      Opt.some("Bad instruction")
    elif "OutOfBounds" in info:
      Opt.some("Out of bounds")
    elif "OutOfGas" in info or "GasIntOverflow" in info:
      Opt.some("Out of gas")
    else:
      Opt.some(info)

func isReverted(comp: Computation): bool =
  (not comp.isSuccess) and (not comp.error.isNil) and
    comp.error.status == StatusCode.Revert

func pushCount(op: Op): int =
  case op
  of Stop, Jump, JumpDest, Pop, Mstore, Mstore8, Sstore, Tstore,
     CallDataCopy, CodeCopy, ExtCodeCopy, ReturnDataCopy, Mcopy,
     Log0, Log1, Log2, Log3, Log4,
     Return, Revert, SelfDestruct, Invalid:
    0
  of Dup1..Dup16:
    ord(op) - ord(Dup1) + 2
  of Swap1..Swap16:
    ord(op) - ord(Swap1) + 2
  else:
    1

proc snapAccount(ctx: ParityTracer, comp: Computation, acct: Address) =
  if acct in ctx.preState:
    return
  let ledger  = comp.vmState.ledger
  let codeRef = ledger.getCode(acct)
  ctx.preState[acct] = AccountSnap(
    balance: ledger.getBalance(acct),
    nonce:   ledger.getNonce(acct),
    code:    if codeRef.isNil: @[] else: @(codeRef.bytes()),
    exists:  ledger.accountExists(acct))

proc preSnap*(ctx: ParityTracer, ledger: LedgerRef, acct: Address) =
  if acct in ctx.preState:
    return
  let codeRef = ledger.getCode(acct)
  ctx.preState[acct] = AccountSnap(
    balance: ledger.getBalance(acct),
    nonce:   ledger.getNonce(acct),
    code:    if codeRef.isNil: @[] else: @(codeRef.bytes()),
    exists:  ledger.accountExists(acct))

proc snapStorage(ctx: ParityTracer, comp: Computation, acct: Address, slot: UInt256) =
  discard ctx.preStorage.mgetOrPut(acct, initTable[UInt256, UInt256]())
  ctx.preStorage.withValue(acct, inner):
    if slot notin inner[]:
      inner[][slot] = comp.vmState.ledger.getStorage(acct, slot)

proc addSkeleton(ctx: ParityTracer, frame: var ParityFrame) =
  if ttTrace notin ctx.traceTypes:
    frame.resultIdx = -1
    return
  frame.resultIdx = ctx.results.len
  let typeStr =
    case frame.actionKind
    of takCall:    "call"
    of takCreate:  "create"
    of takSuicide: "suicide"
    of takReward:  "reward"
  ctx.results.add TraceObject(
    action:              frame.action,
    result:              Opt.none(TraceResult),
    error:               Opt.none(string),
    subtraces:           0,
    traceAddress:        frame.traceAddr,
    `type`:              typeStr,
    blockHash:           Opt.none(Hash32),
    blockNumber:         Opt.none(uint64),
    transactionHash:     Opt.none(Hash32),
    transactionPosition: Opt.none(int))

proc applyResult(ctx: ParityTracer, frame: ParityFrame, comp: Computation,
                 output: openArray[byte], gasUsed: GasInt) =
  if frame.resultIdx < 0:
    return
  let error    = parityError(comp)
  let isRevert = comp.isReverted
  let isHalt   = error.isSome and not isRevert

  let traceResult =
    if isHalt:
      Opt.none(TraceResult)
    elif isRevert:
      Opt.some TraceResult(kind: trkCall,
        callResult: TraceCallResult(
          gasUsed: Quantity(gasUsed),
          output:  @output))
    else:
      case frame.actionKind
      of takCall:
        Opt.some TraceResult(kind: trkCall,
          callResult: TraceCallResult(
            gasUsed: Quantity(gasUsed),
            output:  @output))
      of takCreate:
        Opt.some TraceResult(kind: trkCreate,
          createResult: TraceCreateResult(
            gasUsed: Quantity(gasUsed),
            code:    @output,
            address: Opt.some(frame.createAddress)))
      else:
        Opt.none(TraceResult)

  ctx.results[frame.resultIdx].result    = traceResult
  ctx.results[frame.resultIdx].error     = error
  ctx.results[frame.resultIdx].subtraces = frame.childIndex

method captureStart*(ctx: ParityTracer, comp: Computation,
                     sender: Address, to: Address,
                     create: bool, input: openArray[byte],
                     gasLimit: GasInt, value: UInt256) {.gcsafe.} =
  let frameGas = comp.msg.gas
  let action =
    if create:
      TraceAction(kind: takCreate,
        createAction: TraceCreateAction(
          `from`:         sender,
          gas:            Quantity(frameGas),
          init:           @input,
          value:          value,
          creationMethod: "create"))
    else:
      TraceAction(kind: takCall,
        callAction: TraceCallAction(
          callType: call,
          `from`:   sender,
          to:       to,
          gas:      Quantity(frameGas),
          input:    @input,
          value:    value))

  if ttStateDiff in ctx.traceTypes:
    ctx.snapAccount(comp, sender)
    ctx.snapAccount(comp, to)

  var frame = ParityFrame(
    action:        action,
    actionKind:    if create: takCreate else: takCall,
    traceAddr:     @[],
    createAddress: to)
  ctx.addSkeleton(frame)
  ctx.frames.add frame

method captureEnter*(ctx: ParityTracer, comp: Computation, op: Op,
                     sender: Address, to: Address,
                     input: openArray[byte], gasLimit: GasInt,
                     value: UInt256) {.gcsafe.} =
  if ctx.frames.len == 0:
    return

  let isCreate = op in {Create, Create2}

  if not isCreate and value.isZero and
     isPrecompile(comp.fork, comp.msg.codeAddress):
    ctx.frames.add ParityFrame(skip: true, resultIdx: -1)
    return

  let childAddr = ctx.frames[^1].traceAddr & @[ctx.frames[^1].childIndex]
  inc ctx.frames[^1].childIndex

  let (actFrom, actTo) =
    if op in {DelegateCall, CallCode}:
      (comp.msg.currentTarget, comp.msg.codeAddress)
    else:
      (sender, to)

  let action =
    if isCreate:
      TraceAction(kind: takCreate,
        createAction: TraceCreateAction(
          `from`:         actFrom,
          gas:            Quantity(gasLimit),
          init:           @input,
          value:          value,
          creationMethod: if op == Create2: "create2" else: "create"))
    else:
      TraceAction(kind: takCall,
        callAction: TraceCallAction(
          callType: callTypeForOp(op),
          `from`:   actFrom,
          to:       actTo,
          gas:      Quantity(gasLimit),
          input:    @input,
          value:    value))

  if ttStateDiff in ctx.traceTypes:
    ctx.snapAccount(comp, actFrom)
    if not isCreate:
      ctx.snapAccount(comp, actTo)
    else:
      ctx.snapAccount(comp, to)

  var frame = ParityFrame(
    action:        action,
    actionKind:    if isCreate: takCreate else: takCall,
    traceAddr:     childAddr,
    createAddress: to)
  ctx.addSkeleton(frame)
  ctx.frames.add frame

method captureOpStart*(ctx: ParityTracer, comp: Computation,
                       fixed: bool, pc: int, op: Op, gas: GasInt,
                       depth: int): int {.gcsafe.} =
  if ctx.frames.len == 0 or ctx.frames[^1].skip:
    return 0

  if ttTrace in ctx.traceTypes and op == SelfDestruct:
    let target  = comp.msg.currentTarget
    let refund  = comp.stack[^1, Address].valueOr(Address.default)
    let bal     = comp.vmState.ledger.getBalance(target)
    let parent  = ctx.frames[^1]
    let suicideAddr = parent.traceAddr & @[parent.childIndex]
    ctx.results.add TraceObject(
      action: TraceAction(kind: takSuicide,
        suicideAction: TraceSuicideAction(
          address:       target,
          refundAddress: refund,
          balance:       bal)),
      result:              Opt.none(TraceResult),
      error:               Opt.none(string),
      subtraces:           0,
      traceAddress:        suicideAddr,
      `type`:              "suicide",
      blockHash:           Opt.none(Hash32),
      blockNumber:         Opt.none(uint64),
      transactionHash:     Opt.none(Hash32),
      transactionPosition: Opt.none(int))
    inc ctx.frames[^1].childIndex

  if ttStateDiff in ctx.traceTypes:
    case op
    of Sload, Sstore:
      if comp.stack.len >= 1:
        let slot = comp.stack[^1, UInt256].valueOr(0.u256)
        ctx.snapStorage(comp, comp.msg.currentTarget, slot)
    of SelfDestruct:
      ctx.snapAccount(comp, comp.msg.currentTarget)
      if comp.stack.len >= 1:
        ctx.snapAccount(comp, comp.stack[^1, Address].valueOr(Address.default))
    else:
      discard

  if ttVmTrace in ctx.traceTypes:
    if ctx.frames[^1].vmTrace.code.len == 0 and ctx.frames[^1].vmTrace.ops.len == 0:
      ctx.frames[^1].vmTrace.code = comp.code.bytes
    var pending = PendingOp(
      active: true,
      op:     op,
      vmOp:   VmTraceOp(pc: pc))
    case op
    of Mstore:
      if comp.stack.len >= 2:
        pending.memKind = mrStored
        pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
        pending.memData = @(comp.stack[^2, UInt256].valueOr(0.u256).toBytesBE)
    of Mstore8:
      if comp.stack.len >= 2:
        pending.memKind = mrStored
        pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
        let v = comp.stack[^2, UInt256].valueOr(0.u256)
        pending.memData = @[byte(v.and(255.u256).truncate(uint8))]
    of Mload:
      if comp.stack.len >= 1:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = 32
    of CallDataCopy, CodeCopy, ReturnDataCopy:
      if comp.stack.len >= 3:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = comp.stack[^3, UInt256].valueOr(0.u256).cleanMemRef
    of Mcopy:
      if comp.stack.len >= 3:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = comp.stack[^3, UInt256].valueOr(0.u256).cleanMemRef
    of ExtCodeCopy:
      if comp.stack.len >= 4:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^2, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = comp.stack[^4, UInt256].valueOr(0.u256).cleanMemRef
    of Call, CallCode:
      if comp.stack.len >= 7:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^6, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = comp.stack[^7, UInt256].valueOr(0.u256).cleanMemRef
    of DelegateCall, StaticCall:
      if comp.stack.len >= 6:
        pending.memKind = mrWindow
        pending.memOff  = comp.stack[^5, UInt256].valueOr(0.u256).cleanMemRef
        pending.memLen  = comp.stack[^6, UInt256].valueOr(0.u256).cleanMemRef
    else:
      discard
    if op == Sstore and comp.stack.len >= 2:
      pending.isStore  = true
      pending.storeKey = comp.stack[^1, UInt256].valueOr(0.u256)
      pending.storeVal = comp.stack[^2, UInt256].valueOr(0.u256)
    ctx.frames[^1].pending = pending

  0

method captureGasCost*(ctx: ParityTracer, comp: Computation,
                       fixed: bool, op: Op, gasCost: GasInt,
                       executionGasLeft: GasInt, depth: int) {.gcsafe.} =
  if ttVmTrace notin ctx.traceTypes or ctx.frames.len == 0:
    return
  if ctx.frames[^1].pending.active:
    ctx.frames[^1].pending.vmOp.cost = gasCost

method captureOpEnd*(ctx: ParityTracer, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: int64,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.gcsafe.} =
  if ttVmTrace notin ctx.traceTypes or ctx.frames.len == 0:
    return
  let pending = ctx.frames[^1].pending
  if not pending.active:
    return

  var ex = VmTraceOpEx(used: gas)

  let n = pushCount(pending.op)
  if n > 0 and comp.stack.len >= n:
    for i in countdown(n, 1):
      ex.push.add comp.stack[^i, UInt256].valueOr(0.u256)

  if pending.isStore:
    ex.store = Opt.some((key: pending.storeKey, val: pending.storeVal))

  case pending.memKind
  of mrStored:
    ex.mem = Opt.some((off: pending.memOff, data: pending.memData))
  of mrWindow:
    if pending.memLen > 0 and
       pending.memOff + pending.memLen <= comp.memory.len:
      ex.mem = Opt.some((off: pending.memOff,
                         data: @(comp.memory.read(pending.memOff, pending.memLen))))
  of mrNone:
    discard

  var vmOp  = pending.vmOp
  vmOp.ex   = Opt.some(ex)
  ctx.frames[^1].vmTrace.ops.add vmOp
  ctx.frames[^1].pending.active = false

method captureExit*(ctx: ParityTracer, comp: Computation,
                    output: openArray[byte], gasUsed: GasInt,
                    error: Opt[string]) {.gcsafe.} =
  if ctx.frames.len <= 1:
    return
  let subFrame = ctx.frames.pop()
  if subFrame.skip:
    return

  if ttVmTrace in ctx.traceTypes and ctx.frames.len > 0:
    if ctx.frames[^1].pending.active:
      ctx.frames[^1].pending.vmOp.sub = Opt.some(subFrame.vmTrace)

  ctx.applyResult(subFrame, comp, output, gasUsed)

method captureEnd*(ctx: ParityTracer, comp: Computation,
                   output: openArray[byte], gasUsed: GasInt,
                   error: Opt[string]) {.gcsafe.} =
  if ctx.frames.len == 0:
    return
  let frame = ctx.frames.pop()

  if ttVmTrace in ctx.traceTypes:
    var vmOp = frame.pending.vmOp
    if frame.pending.active:
      vmOp.ex = Opt.some(VmTraceOpEx(used: gasUsed))
      var trace = frame.vmTrace
      trace.ops.add vmOp
      ctx.vmTrace = Opt.some(trace)
    else:
      ctx.vmTrace = Opt.some(frame.vmTrace)

  ctx.output = @output

  ctx.applyResult(frame, comp, output, gasUsed)

proc finalizeStateDiff*(ctx: ParityTracer, ledger: LedgerRef) =
  if ttStateDiff notin ctx.traceTypes:
    return
  ctx.stateDiff = StateDiff()
  for acct, snap in ctx.preState:
    let codeRef    = ledger.getCode(acct)
    let newCode    = if codeRef.isNil: @[] else: @(codeRef.bytes())
    let newBal     = ledger.getBalance(acct)
    let newNonce   = ledger.getNonce(acct)
    let postExists = ledger.accountExists(acct)

    var diff = AccountDiff()
    diff.born = postExists and not snap.exists
    diff.died = snap.exists and not postExists

    if diff.born:
      diff.balance = Opt.some(BalanceDiff(`from`: 0.u256, to: newBal))
      diff.nonce   = Opt.some(NonceDiff(`from`: 0, to: newNonce))
      diff.code    = Opt.some((`from`: newSeq[byte](), to: newCode))
      ctx.preStorage.withValue(acct, inner):
        for slot, _ in inner[]:
          let postVal = ledger.getStorage(acct, slot)
          if not postVal.isZero:
            diff.storage[slot] = StorageDiff(`from`: 0.u256, to: postVal)
      ctx.stateDiff[acct] = diff
    elif diff.died:
      diff.balance = Opt.some(BalanceDiff(`from`: snap.balance, to: 0.u256))
      diff.nonce   = Opt.some(NonceDiff(`from`: snap.nonce, to: 0))
      diff.code    = Opt.some((`from`: snap.code, to: newSeq[byte]()))
      ctx.stateDiff[acct] = diff
    else:
      if not (snap.exists or postExists):
        continue
      if newBal != snap.balance:
        diff.balance = Opt.some(BalanceDiff(`from`: snap.balance, to: newBal))
      if newNonce != snap.nonce:
        diff.nonce = Opt.some(NonceDiff(`from`: snap.nonce, to: newNonce))
      if newCode != snap.code:
        diff.code = Opt.some((`from`: snap.code, to: newCode))
      ctx.preStorage.withValue(acct, inner):
        for slot, preVal in inner[]:
          let postVal = ledger.getStorage(acct, slot)
          if postVal != preVal:
            diff.storage[slot] = StorageDiff(`from`: preVal, to: postVal)
      if diff.balance.isSome or diff.nonce.isSome or diff.code.isSome or
         diff.storage.len > 0:
        ctx.stateDiff[acct] = diff
