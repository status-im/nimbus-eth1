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
  std/[tables, hashes],
  results,
  eth/common/eth_types,
  web3/eth_api_types,
  ".."/[types, stack],
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

  PendingOp = object
    active:   bool
    prelen:   int
    op:       Op
    vmOp:     VmTraceOp
    storeKey: UInt256
    storeVal: UInt256
    isStore:  bool
    memOff:   int
    memData:  seq[byte]
    isMem:    bool

  ParityFrame = object
    action:        TraceAction
    actionKind:    TraceActionKind
    traceAddr:     seq[int]
    childIndex:    int
    createAddress: EthAddress
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

proc snapAccount(ctx: ParityTracer, comp: Computation, acct: Address) =
  if acct in ctx.preState:
    return
  let ledger  = comp.vmState.ledger
  let codeRef = ledger.getCode(acct)
  ctx.preState[acct] = AccountSnap(
    balance: ledger.getBalance(acct),
    nonce:   ledger.getNonce(acct),
    code:    if codeRef.isNil: @[] else: @(codeRef.bytes()))

proc snapStorage(ctx: ParityTracer, comp: Computation, acct: Address, slot: UInt256) =
  discard ctx.preStorage.mgetOrPut(acct, initTable[UInt256, UInt256]())
  ctx.preStorage.withValue(acct, inner):
    if slot notin inner[]:
      inner[][slot] = comp.vmState.ledger.getStorage(acct, slot)

proc frameCode(comp: Computation, isCreate: bool, input: openArray[byte], to: Address): seq[byte] =
  if isCreate:
    @input
  else:
    let codeRef = comp.vmState.ledger.getCode(to)
    if codeRef.isNil: @[] else: @(codeRef.bytes())

proc applyResult(ctx: ParityTracer, frame: ParityFrame,
                 output: openArray[byte], gasUsed: GasInt,
                 error: Opt[string]) =
  let isRevert = error.isSome and error.get == "Reverted"
  let isHalt   = error.isSome and not isRevert

  let traceResult =
    if isHalt:
      Opt.none(TraceResult)
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
            address: if isRevert: Opt.none(Address) else: Opt.some(frame.createAddress)))
      else:
        Opt.none(TraceResult)

  let typeStr =
    case frame.actionKind
    of takCall:    "call"
    of takCreate:  "create"
    of takSuicide: "suicide"
    of takReward:  "reward"

  ctx.results.add TraceObject(
    action:              frame.action,
    result:              traceResult,
    error:               error,
    subtraces:           frame.childIndex,
    traceAddress:        frame.traceAddr,
    `type`:              typeStr,
    blockHash:           Opt.none(Hash32),
    blockNumber:         Opt.none(uint64),
    transactionHash:     Opt.none(Hash32),
    transactionPosition: Opt.none(int))

proc computeStateDiff(ctx: ParityTracer, comp: Computation) =
  let ledger = comp.vmState.ledger
  for acct, snap in ctx.preState:
    let codeRef = ledger.getCode(acct)
    let newCode = if codeRef.isNil: @[] else: @(codeRef.bytes())
    var diff     = AccountDiff()
    let newBal   = ledger.getBalance(acct)
    let newNonce = ledger.getNonce(acct)
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
    ctx.stateDiff[acct] = diff

method captureStart*(ctx: ParityTracer, comp: Computation,
                     sender: Address, to: Address,
                     create: bool, input: openArray[byte],
                     gasLimit: GasInt, value: UInt256) {.gcsafe.} =
  let action =
    if create:
      TraceAction(kind: takCreate,
        createAction: TraceCreateAction(
          `from`: sender,
          gas:    Quantity(gasLimit),
          init:   @input,
          value:  value))
    else:
      TraceAction(kind: takCall,
        callAction: TraceCallAction(
          callType: call,
          `from`:   sender,
          to:       to,
          gas:      Quantity(gasLimit),
          input:    @input,
          value:    value))

  if ttStateDiff in ctx.traceTypes:
    ctx.snapAccount(comp, sender)
    if not create:
      ctx.snapAccount(comp, to)

  ctx.frames.add ParityFrame(
    action:        action,
    actionKind:    if create: takCreate else: takCall,
    traceAddr:     @[],
    createAddress: to,
    vmTrace:       VmTrace(code: frameCode(comp, create, input, to)))

method captureEnter*(ctx: ParityTracer, comp: Computation, op: Op,
                     sender: Address, to: Address,
                     input: openArray[byte], gasLimit: GasInt,
                     value: UInt256) {.gcsafe.} =
  if ctx.frames.len == 0:
    return

  let childAddr = ctx.frames[^1].traceAddr & @[ctx.frames[^1].childIndex]
  inc ctx.frames[^1].childIndex

  let isCreate = op in {Create, Create2}
  let action =
    if isCreate:
      TraceAction(kind: takCreate,
        createAction: TraceCreateAction(
          `from`: sender,
          gas:    Quantity(gasLimit),
          init:   @input,
          value:  value))
    else:
      TraceAction(kind: takCall,
        callAction: TraceCallAction(
          callType: callTypeForOp(op),
          `from`:   sender,
          to:       to,
          gas:      Quantity(gasLimit),
          input:    @input,
          value:    value))

  if ttStateDiff in ctx.traceTypes:
    ctx.snapAccount(comp, sender)
    if not isCreate:
      ctx.snapAccount(comp, to)

  ctx.frames.add ParityFrame(
    action:        action,
    actionKind:    if isCreate: takCreate else: takCall,
    traceAddr:     childAddr,
    createAddress: to,
    vmTrace:       VmTrace(code: frameCode(comp, isCreate, input, to)))

method captureOpStart*(ctx: ParityTracer, comp: Computation,
                       fixed: bool, pc: int, op: Op, gas: GasInt,
                       depth: int): int {.gcsafe.} =
  if ttTrace in ctx.traceTypes and op == SelfDestruct and ctx.frames.len > 0:
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

  if ttStateDiff in ctx.traceTypes and ctx.frames.len > 0:
    case op
    of Sload, Sstore:
      if comp.stack.len >= 1:
        let slot = comp.stack[^1, UInt256].valueOr(0.u256)
        ctx.snapStorage(comp, comp.msg.currentTarget, slot)
    else:
      discard

  if ttVmTrace in ctx.traceTypes and ctx.frames.len > 0:
    var pending = PendingOp(
      active: true,
      prelen: comp.stack.len,
      op:     op,
      vmOp:   VmTraceOp(pc: pc))
    if op == Mstore and comp.stack.len >= 2:
      pending.isMem  = true
      pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
      pending.memData = @(comp.stack[^2, UInt256].valueOr(0.u256).toBytesBE)
    elif op == Mstore8 and comp.stack.len >= 2:
      pending.isMem   = true
      pending.memOff  = comp.stack[^1, UInt256].valueOr(0.u256).cleanMemRef
      let v = comp.stack[^2, UInt256].valueOr(0.u256)
      pending.memData = @[byte(v.and(255.u256).truncate(uint8))]
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

  if pending.isStore:
    ex.store = Opt.some((key: pending.storeKey, val: pending.storeVal))

  if pending.isMem:
    ex.mem = Opt.some((off: pending.memOff, data: pending.memData))

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

  if ttVmTrace in ctx.traceTypes and ctx.frames.len > 0:
    if ctx.frames[^1].pending.active:
      ctx.frames[^1].pending.vmOp.sub = Opt.some(subFrame.vmTrace)

  ctx.applyResult(subFrame, output, gasUsed, error)

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

  if ttStateDiff in ctx.traceTypes:
    ctx.computeStateDiff(comp)

  ctx.applyResult(frame, output, gasUsed, error)
