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
  std/json,
  stew/byteutils,
  stint,
  json_rpc/rpcserver,
  web3/[eth_api_types, conversions],
  eth/common/eth_types_rlp,
  ./rpc_utils,
  ./rpc_types,
  ./trace_types,
  ../evm/[types, state],
  ../evm/tracer/parity_tracer,
  ../transaction,
  ../transaction/call_evm_rpc,
  ../common/common,
  ../core/tx_pool,
  ../core/chain/forked_chain,
  ../core/executor

func blockRewardWei(fork: EVMFork): UInt256 =
  func eth(n: int): UInt256 {.compileTime.} =
    n.u256 * pow(10.u256, 18)
  const
    w5 = 5.eth
    w3 = 3.eth
    w2 = 2.eth
  if   fork < FkByzantium:      w5
  elif fork < FkConstantinople: w3
  elif fork < FkParis:          w2
  else:                         0.u256

proc parseTraceTypes(types: seq[string]): set[TraceTypeFlag] =
  for t in types:
    case t
    of "trace":     result.incl TraceTypeFlag.ttTrace
    of "stateDiff": result.incl TraceTypeFlag.ttStateDiff
    of "vmTrace":   result.incl TraceTypeFlag.ttVmTrace
    else: discard

func matchesFilter(t: TraceObject, f: TraceFilterRequest): bool =
  if f.fromAddress.isSome:
    let froms = f.fromAddress.get
    if froms.len > 0:
      let actionFrom =
        case t.action.kind
        of takCall:    t.action.callAction.`from`
        of takCreate:  t.action.createAction.`from`
        of takSuicide: t.action.suicideAction.address
        of takReward:  t.action.rewardAction.author
      if actionFrom notin froms:
        return false
  if f.toAddress.isSome:
    let tos = f.toAddress.get
    if tos.len > 0:
      case t.action.kind
      of takCall:
        if t.action.callAction.to notin tos:
          return false
      else:
        return false
  true

proc actionToJson(action: TraceAction): JsonNode =
  result = newJObject()
  case action.kind
  of takCall:
    let a = action.callAction
    result["callType"] = newJString($a.callType)
    result["from"]     = newJString(a.`from`.to0xHex)
    result["to"]       = newJString(a.to.to0xHex)
    result["gas"]      = newJString($a.gas)
    result["input"]    = newJString(a.input.to0xHex)
    result["value"]    = newJString("0x" & a.value.toHex)
  of takCreate:
    let a = action.createAction
    result["from"]  = newJString(a.`from`.to0xHex)
    result["gas"]   = newJString($a.gas)
    result["init"]  = newJString(a.init.to0xHex)
    result["value"] = newJString("0x" & a.value.toHex)
  of takSuicide:
    let a = action.suicideAction
    result["address"]       = newJString(a.address.to0xHex)
    result["refundAddress"] = newJString(a.refundAddress.to0xHex)
    result["balance"]       = newJString("0x" & a.balance.toHex)
  of takReward:
    let a = action.rewardAction
    result["author"]     = newJString(a.author.to0xHex)
    result["rewardType"] = newJString(a.rewardType)
    result["value"]      = newJString("0x" & a.value.toHex)

proc resultToJson(r: TraceResult): JsonNode =
  result = newJObject()
  case r.kind
  of trkCall:
    result["gasUsed"] = newJString($r.callResult.gasUsed)
    result["output"]  = newJString(r.callResult.output.to0xHex)
  of trkCreate:
    result["gasUsed"] = newJString($r.createResult.gasUsed)
    result["code"]    = newJString(r.createResult.code.to0xHex)
    if r.createResult.address.isSome:
      result["address"] = newJString(r.createResult.address.get.to0xHex)

proc traceObjectToJson(t: TraceObject): JsonNode =
  result = newJObject()
  result["action"] = actionToJson(t.action)
  if t.result.isSome:
    result["result"] = resultToJson(t.result.get)
  if t.error.isSome:
    result["error"] = newJString(t.error.get)
  result["subtraces"] = newJInt(t.subtraces)
  let addrArr = newJArray()
  for a in t.traceAddress:
    addrArr.add newJInt(a)
  result["traceAddress"] = addrArr
  result["type"] = newJString(t.`type`)
  if t.blockHash.isSome:
    result["blockHash"] = newJString(t.blockHash.get.to0xHex)
  if t.blockNumber.isSome:
    result["blockNumber"] = newJInt(t.blockNumber.get.int64)
  if t.transactionHash.isSome:
    result["transactionHash"] = newJString(t.transactionHash.get.to0xHex)
  if t.transactionPosition.isSome:
    result["transactionPosition"] = newJInt(t.transactionPosition.get)

proc tracesToJson(traces: seq[TraceObject]): JsonNode =
  result = newJArray()
  for t in traces:
    result.add traceObjectToJson(t)

proc vmTraceToJson(vt: VmTrace): JsonNode {.gcsafe.}

proc vmTraceOpToJson(op: VmTraceOp): JsonNode {.gcsafe.} =
  result = newJObject()
  result["pc"]   = newJInt(op.pc)
  result["cost"] = newJInt(op.cost.BiggestInt)
  if op.ex.isSome:
    let ex  = op.ex.get
    let exJ = newJObject()
    if ex.mem.isSome:
      let m = ex.mem.get
      let mJ = newJObject()
      mJ["off"]  = newJInt(m.off)
      mJ["data"] = newJString(m.data.to0xHex)
      exJ["mem"] = mJ
    else:
      exJ["mem"] = newJNull()
    let pushArr = newJArray()
    for v in ex.push:
      pushArr.add newJString("0x" & v.toHex)
    exJ["push"]  = pushArr
    if ex.store.isSome:
      let s  = ex.store.get
      let sJ = newJObject()
      sJ["key"] = newJString("0x" & s.key.toHex)
      sJ["val"] = newJString("0x" & s.val.toHex)
      exJ["store"] = sJ
    else:
      exJ["store"] = newJNull()
    exJ["used"]  = newJInt(ex.used.BiggestInt)
    result["ex"] = exJ
  else:
    result["ex"] = newJNull()
  if op.sub.isSome:
    result["sub"] = vmTraceToJson(op.sub.get)
  else:
    result["sub"] = newJNull()

proc vmTraceToJson(vt: VmTrace): JsonNode {.gcsafe.} =
  result = newJObject()
  result["code"] = newJString(vt.code.to0xHex)
  let ops = newJArray()
  for op in vt.ops:
    ops.add vmTraceOpToJson(op)
  result["ops"] = ops

proc stateDiffToJson(sd: StateDiff): JsonNode =
  result = newJObject()
  for addr, diff in sd:
    let addrJ = newJObject()
    if diff.balance.isSome:
      let b  = diff.balance.get
      let bJ = newJObject()
      bJ["from"] = newJString("0x" & b.`from`.toHex)
      bJ["to"]   = newJString("0x" & b.to.toHex)
      addrJ["balance"] = bJ
    else:
      addrJ["balance"] = newJString("=")
    if diff.nonce.isSome:
      let n  = diff.nonce.get
      let nJ = newJObject()
      nJ["from"] = newJString("0x" & n.`from`.toHex)
      nJ["to"]   = newJString("0x" & n.to.toHex)
      addrJ["nonce"] = nJ
    else:
      addrJ["nonce"] = newJString("=")
    if diff.code.isSome:
      let c  = diff.code.get
      let cJ = newJObject()
      cJ["from"] = newJString(c.`from`.to0xHex)
      cJ["to"]   = newJString(c.to.to0xHex)
      addrJ["code"] = cJ
    else:
      addrJ["code"] = newJString("=")
    let storJ = newJObject()
    for slot, sDiff in diff.storage:
      let sJ = newJObject()
      sJ["from"] = newJString("0x" & sDiff.`from`.toHex)
      sJ["to"]   = newJString("0x" & sDiff.to.toHex)
      storJ["0x" & slot.toHex] = sJ
    addrJ["storage"] = storJ
    result[addr.to0xHex] = addrJ

proc replayTx(com: CommonRef, chain: ForkedChainRef, blk: Block,
              txIndex: int, blockHash: Hash32,
              traceTypes: set[TraceTypeFlag]): ParityTracer =
  let
    txFrame    = chain.txFrame(blk.header)
    tracerInst = newParityTracer(traceTypes)
    vmState    = BaseVMState.new(
      Header(number: blk.header.number - 1), blk.header, com, txFrame)
  defer:
    vmState.dispose()
    txFrame.dispose()
  for idx, tx in blk.transactions:
    if idx == txIndex:
      vmState.tracer = tracerInst
    let sender = tx.recoverSenderCached().expect("valid signature")
    discard vmState.processTransaction(tx, sender)
    if idx == txIndex:
      break
  let txHash = blk.transactions[txIndex].computeRlpHash()
  for i in 0 ..< tracerInst.results.len:
    tracerInst.results[i].blockHash            = Opt.some(blockHash)
    tracerInst.results[i].blockNumber          = Opt.some(blk.header.number)
    tracerInst.results[i].transactionHash      = Opt.some(txHash)
    tracerInst.results[i].transactionPosition  = Opt.some(txIndex)
  tracerInst

proc rewardTraceObject(author: Address, value: UInt256,
                       rewardType: string, blockHash: Hash32,
                       blockNumber: uint64): TraceObject =
  TraceObject(
    action: TraceAction(kind: takReward,
      rewardAction: TraceRewardAction(
        author:     author,
        rewardType: rewardType,
        value:      value)),
    result:              Opt.none(TraceResult),
    error:               Opt.none(string),
    subtraces:           0,
    traceAddress:        @[],
    `type`:              "reward",
    blockHash:           Opt.some(blockHash),
    blockNumber:         Opt.some(blockNumber),
    transactionHash:     Opt.none(Hash32),
    transactionPosition: Opt.none(int))

proc buildRewardTraces(com: CommonRef, header: Header, blk: Block,
                       blockHash: Hash32): seq[TraceObject] =
  let fork   = com.toEVMFork(header)
  let reward = blockRewardWei(fork)
  if reward == 0.u256:
    return
  var mainReward = reward
  for uncle in blk.uncles:
    var uncleReward = uncle.number.u256 + 8.u256
    uncleReward    -= header.number.u256
    uncleReward     = uncleReward * reward
    uncleReward     = uncleReward div 8.u256
    result.add rewardTraceObject(uncle.coinbase, uncleReward,
                                 "uncle", blockHash, header.number)
    mainReward += reward div 32.u256
  result.add rewardTraceObject(header.coinbase, mainReward,
                               "block", blockHash, header.number)

proc setupTraceRpc*(com: CommonRef, txPool: TxPoolRef, server: RpcServer) =
  let chain = txPool.chain

  server.rpc(EthJson):
    proc trace_call(args: TransactionArgs, traceTypes: seq[string],
                    quantityTag: Opt[BlockTag]): JsonNode {.raises: [RpcResponseError].} =
      let
        tag        = quantityTag.get(blockId("latest"))
        header     = chain.headerFromTag(tag).valueOr:
          raise invalidParams(error)
        txFrame    = chain.txFrame(header)
        flags      = parseTraceTypes(traceTypes)
        tracerInst = newParityTracer(flags)
        vmState    = BaseVMState.new(
          Header(number: header.number - 1), header, com, txFrame, tracerInst)
      defer:
        vmState.dispose()
        txFrame.dispose()
      let callRes = rpcCallEvm(args, header, vmState).valueOr:
        raise invalidParams(error)
      let res = newJObject()
      res["output"] = newJString(callRes.output.to0xHex)
      res["stateDiff"] =
        if ttStateDiff in flags: stateDiffToJson(tracerInst.stateDiff)
        else: newJNull()
      res["trace"] = tracesToJson(tracerInst.results)
      res["vmTrace"] =
        if ttVmTrace in flags and tracerInst.vmTrace.isSome:
          vmTraceToJson(tracerInst.vmTrace.get)
        else: newJNull()
      res

    proc trace_callMany(calls: JsonNode,
                        quantityTag: Opt[BlockTag]): JsonNode {.raises: [RpcResponseError].} =
      if calls.kind != JArray:
        raise invalidParams("calls must be an array")
      let
        tag     = quantityTag.get(blockId("latest"))
        header  = chain.headerFromTag(tag).valueOr:
          raise invalidParams(error)
        txFrame = chain.txFrame(header)
        vmState = BaseVMState.new(
          Header(number: header.number - 1), header, com, txFrame)
      defer:
        vmState.dispose()
        txFrame.dispose()
      let res = newJArray()
      for callItem in calls:
        if callItem.kind != JArray or callItem.len < 2:
          raise invalidParams("each call must be [TransactionArgs, traceTypes]")
        let args =
          try:
            EthJson.decode($(callItem[0]), TransactionArgs)
          except SerializationError as e:
            raise invalidParams("invalid call args: " & e.msg)
        var traceTypeStrs: seq[string]
        if callItem[1].kind == JArray:
          for t in callItem[1]:
            if t.kind == JString:
              traceTypeStrs.add t.str
        let
          flags      = parseTraceTypes(traceTypeStrs)
          tracerInst = newParityTracer(flags)
        vmState.tracer = tracerInst
        let callRes = rpcCallEvm(args, header, vmState)
        let entry = newJObject()
        entry["output"] = newJString(
          if callRes.isOk: callRes.get.output.to0xHex else: "0x")
        entry["stateDiff"] =
          if ttStateDiff in flags: stateDiffToJson(tracerInst.stateDiff)
          else: newJNull()
        entry["trace"]   = tracesToJson(tracerInst.results)
        entry["vmTrace"] =
          if ttVmTrace in flags and tracerInst.vmTrace.isSome:
            vmTraceToJson(tracerInst.vmTrace.get)
          else: newJNull()
        res.add entry
      res

    proc trace_transaction(txHash: Hash32): JsonNode {.raises: [RpcResponseError].} =
      let
        (blockHash, txIndex) = chain.txDetailsByTxHash(txHash).valueOr:
          raise invalidParams("Transaction not found")
        blk = chain.blockByHash(blockHash).valueOr:
          raise invalidParams("Block not found")
        tracer = replayTx(com, chain, blk, int(txIndex), blockHash,
                          {TraceTypeFlag.ttTrace})
      tracesToJson(tracer.results)

    proc trace_block(quantityTag: BlockTag): JsonNode {.raises: [RpcResponseError].} =
      let
        header    = chain.headerFromTag(quantityTag).valueOr:
          raise invalidParams(error)
        blockHash = header.computeBlockHash()
        blk       = chain.blockByHash(blockHash).valueOr:
          raise invalidParams("Block not found")
      let res = newJArray()
      for i in 0 ..< blk.transactions.len:
        let tracer = replayTx(com, chain, blk, i, blockHash,
                              {TraceTypeFlag.ttTrace})
        for t in tracer.results:
          res.add traceObjectToJson(t)
      for t in buildRewardTraces(com, header, blk, blockHash):
        res.add traceObjectToJson(t)
      res

    proc trace_replayTransaction(txHash: Hash32,
                                 traceTypes: seq[string]): JsonNode {.raises: [RpcResponseError].} =
      let
        (blockHash, txIndex) = chain.txDetailsByTxHash(txHash).valueOr:
          raise invalidParams("Transaction not found")
        blk = chain.blockByHash(blockHash).valueOr:
          raise invalidParams("Block not found")
        flags  = parseTraceTypes(traceTypes)
        tracer = replayTx(com, chain, blk, int(txIndex), blockHash, flags)
      let res = newJObject()
      res["output"] = newJString(tracer.output.to0xHex)
      res["stateDiff"] =
        if ttStateDiff in flags: stateDiffToJson(tracer.stateDiff)
        else: newJNull()
      res["trace"] = tracesToJson(tracer.results)
      res["vmTrace"] =
        if ttVmTrace in flags and tracer.vmTrace.isSome:
          vmTraceToJson(tracer.vmTrace.get)
        else: newJNull()
      res

    proc trace_replayBlockTransactions(quantityTag: BlockTag,
                                       traceTypes: seq[string]): JsonNode {.raises: [RpcResponseError].} =
      let
        header    = chain.headerFromTag(quantityTag).valueOr:
          raise invalidParams(error)
        blockHash = header.computeBlockHash()
        blk       = chain.blockByHash(blockHash).valueOr:
          raise invalidParams("Block not found")
        flags     = parseTraceTypes(traceTypes)
      let res = newJArray()
      for i in 0 ..< blk.transactions.len:
        let tracer = replayTx(com, chain, blk, i, blockHash, flags)
        let entry  = newJObject()
        entry["output"] = newJString(tracer.output.to0xHex)
        entry["stateDiff"] =
          if ttStateDiff in flags: stateDiffToJson(tracer.stateDiff)
          else: newJNull()
        entry["trace"]   = tracesToJson(tracer.results)
        entry["vmTrace"] =
          if ttVmTrace in flags and tracer.vmTrace.isSome:
            vmTraceToJson(tracer.vmTrace.get)
          else: newJNull()
        res.add entry
      res

    proc trace_filter(filterReq: TraceFilterRequest): JsonNode {.raises: [RpcResponseError].} =
      let
        fromTag    = filterReq.fromBlock.get(blockId("latest"))
        toTag      = filterReq.toBlock.get(blockId("latest"))
        fromHeader = chain.headerFromTag(fromTag).valueOr:
          raise invalidParams("fromBlock not found")
        toHeader   = chain.headerFromTag(toTag).valueOr:
          raise invalidParams("toBlock not found")
      var
        traces:   seq[TraceObject]
        blockNum = fromHeader.number
      while blockNum <= toHeader.number:
        let header    = chain.headerByNumber(blockNum).valueOr: break
        let blockHash = header.computeBlockHash()
        let blk       = chain.blockByHash(blockHash).valueOr: break
        for i in 0 ..< blk.transactions.len:
          let tracer = replayTx(com, chain, blk, i, blockHash,
                                {TraceTypeFlag.ttTrace})
          for t in tracer.results:
            if matchesFilter(t, filterReq):
              traces.add t
        for t in buildRewardTraces(com, header, blk, blockHash):
          if matchesFilter(t, filterReq):
            traces.add t
        inc blockNum
      let
        afterIdx = filterReq.after.get(0)
        count    = filterReq.count.get(traces.len)
        sliced   =
          if afterIdx < traces.len:
            traces[afterIdx ..< min(afterIdx + count, traces.len)]
          else:
            @[]
      tracesToJson(sliced)
