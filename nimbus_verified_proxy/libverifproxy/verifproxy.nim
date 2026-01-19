# nimbus_verified_proxy
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  stew/byteutils,
  std/[atomics, json, net, strutils, lists],
  beacon_chain/spec/[digest, network],
  beacon_chain/nimbus_binary_common,
  json_rpc/[jsonmarshal],
  web3/[eth_api_types, conversions],
  ../engine/types,
  ../nimbus_verified_proxy_conf,
  ./types,
  ./setup

# for short hand convenience
{.pragma: exported, cdecl, exportc, dynlib, raises: [].}
{.pragma: exportedConst, exportc, dynlib.}

proc NimMain() {.importc, exportc, dynlib.}

var initialized: Atomic[bool]

proc initLib() =
  if not initialized.exchange(true):
    NimMain() # Every Nim library needs to call `NimMain` once exactly
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

proc freeResponse(res: cstring) {.exported.} =
  deallocShared(res)

proc toUnmanagedPtr[T](x: ref T): ptr T =
  GC_ref(x)
  addr x[]

func asRef[T](x: ptr T): ref T =
  cast[ref T](x)

proc destroy[T](x: ptr T) =
  x[].reset()
  GC_unref(asRef(x))

proc freeContext(ctx: ptr Context) {.exported.} =
  ctx.destroy()

proc alloc(str: string): cstring =
  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

proc processVerifProxyTasks(ctx: ptr Context) {.exported.} =
  var delList: seq[int] = @[]

  # cancel all tasks if stopped
  if ctx.stop:
    for task in ctx.tasks:
      task.fut.cancelSoon()

    return

  for taskNode in ctx.tasks.nodes:
    let task = taskNode.value
    if task.finished:
      task.cb(ctx, task.userData, task.status, alloc(task.response))
      ctx.tasks.remove(taskNode)
      ctx.taskLen -= 1

  if ctx.taskLen > 0:
    poll()

proc createTask(cb: CallBackProc, userData: pointer): Task =
  let task = Task()
  task.finished = false
  task.cb = cb
  task.userData = userData
  task

proc startVerifProxy(
    configJson: cstring, userData: pointer, cb: CallBackProc
): ptr Context {.exported.} =
  let ctx = Context.new().toUnmanagedPtr()
  ctx.stop = false

  try:
    initLib()
  except Exception as e:
    cb(ctx, userData, RET_DESER_ERROR, alloc(e.msg))
    return

  let
    task = createTask(cb, userData)
    fut = run(ctx, $configJson)

  proc processFuture[T](fut: Future[T], task: Task) {.gcsafe.} =
    if fut.cancelled():
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = RET_CANCELLED
    elif fut.failed():
      debugEcho "future failed"
      task.response = Json.encode(fut.error())
      task.finished = true
      task.status = RET_ERROR
    else:
      task.response = "success" # since return type is void
      task.finished = true
      task.status = RET_SUCCESS

  if not fut.finished:
    fut.addCallback proc(_: pointer) {.gcsafe.} =
      processFuture(fut, task)
  else:
    processFuture(fut, task)

  task.fut = fut
  ctx.tasks.add(task)
  ctx.taskLen += 1

  return ctx

proc stopVerifProxy(ctx: ptr Context) {.exported.} =
  ctx.stop = true

# NOTE: this is not the C callback. This is just a callback for the future
template callbackToC(
    ctx: ptr Context, userData: pointer, cb: CallBackProc, asyncCall: untyped
) =
  let
    task = createTask(cb, userData)
    fut = asyncCall

  proc processFuture[T](fut: Future[T], task: Task) {.gcsafe.} =
    if fut.cancelled():
      task.response = Json.encode(fut.error().msg)
      task.finished = true
      task.status = RET_CANCELLED
    elif fut.failed():
      task.response = Json.encode(fut.error().msg)
      task.finished = true
      task.status = RET_ERROR
    else:
      let res = fut.value()
      if res.isErr():
        task.response = $res.error.errType & ": " & res.error.errMsg
        task.finished = true
        task.status = RET_ERROR
      else:
        task.response = Json.encode(res.get())
        task.finished = true
        task.status = RET_SUCCESS

  if not fut.finished:
    fut.addCallback proc(_: pointer) {.gcsafe.} =
      processFuture(fut, task)
  else:
    processFuture(fut, task)

  task.fut = fut
  ctx.tasks.add(task)
  ctx.taskLen += 1

# taken from nim-json-rpc and adapted
func unpackArg(
    arg: string, argType: type Address
): Result[Address, string] {.raises: [].} =
  try:
    ok(Address.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudln't be decoded: " & e.msg)

func unpackArg(
    arg: string, argType: type BlockTag
): Result[BlockTag, string] {.raises: [].} =
  try:
    ok(BlockTag(kind: bidNumber, number: Quantity(fromHex[uint64](arg))))
  except ValueError:
    # if it is an invalid alias it verification engine will throw an error
    ok(BlockTag(kind: bidAlias, alias: arg))

func unpackArg(
    arg: string, argType: type UInt256
): Result[UInt256, string] {.raises: [].} =
  try:
    ok(UInt256.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudldn't be decoded: " & e.msg)

func unpackArg(
    arg: string, argType: type Hash32
): Result[Hash32, string] {.raises: [].} =
  try:
    ok(Hash32.fromHex(arg))
  except ValueError as e:
    err("Parameter of type " & $argType & " coudldn't be decoded: " & e.msg)

# generalized overloading
func unpackArg(arg: string, argType: type): Result[argType, string] {.raises: [].} =
  try:
    ok(JrpcConv.decode(arg, argType))
  except CatchableError as e:
    err("Parameter of type " & $argType & " coudln't be decoded: " & e.msg)

proc eth_blockNumber(
    ctx: ptr Context, userData: pointer, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_blockNumber()

proc eth_getBalance(
    ctx: ptr Context,
    userData: pointer,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBalance(addressTyped, blockTagTyped)

proc eth_getStorageAt(
    ctx: ptr Context,
    userData: pointer,
    address: cstring,
    slot: cstring,
    blockTag: cstring,
    cb: CallBackProc,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    slotTyped = unpackArg($slot, UInt256).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getStorageAt(addressTyped, slotTyped, blockTagTyped)

proc eth_getTransactionCount(
    ctx: ptr Context,
    userData: pointer,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getTransactionCount(addressTyped, blockTagTyped)

proc eth_getCode(
    ctx: ptr Context,
    userData: pointer,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getCode(addressTyped, blockTagTyped)

proc eth_getBlockByHash(
    ctx: ptr Context,
    userData: pointer,
    blockHash: cstring,
    fullTransactions: bool,
    cb: CallBackProc,
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBlockByHash(blockHashTyped, fullTransactions)

proc eth_getBlockByNumber(
    ctx: ptr Context,
    userData: pointer,
    blockTag: cstring,
    fullTransactions: bool,
    cb: CallBackProc,
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBlockByNumber(blockTagTyped, fullTransactions)

proc eth_getUncleCountByBlockNumber(
    ctx: ptr Context, userData: pointer, blockTag: cstring, cb: CallBackProc
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getUncleCountByBlockNumber(blockTagTyped)

proc eth_getUncleCountByBlockHash(
    ctx: ptr Context, userData: pointer, blockHash: cstring, cb: CallBackProc
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getUncleCountByBlockHash(blockHashTyped)

proc eth_getBlockTransactionCountByNumber(
    ctx: ptr Context, userData: pointer, blockTag: cstring, cb: CallBackProc
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBlockTransactionCountByNumber(blockTagTyped)

proc eth_getBlockTransactionCountByHash(
    ctx: ptr Context, userData: pointer, blockHash: cstring, cb: CallBackProc
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBlockTransactionCountByHash(blockHashTyped)

proc eth_getTransactionByBlockNumberAndIndex(
    ctx: ptr Context,
    userData: pointer,
    blockTag: cstring,
    index: culonglong,
    cb: CallBackProc,
) {.exported.} =
  let
    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    indexTyped = Quantity(uint64(index))

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getTransactionByBlockNumberAndIndex(blockTagTyped, indexTyped)

proc eth_getTransactionByBlockHashAndIndex(
    ctx: ptr Context,
    userData: pointer,
    blockHash: cstring,
    index: culonglong,
    cb: CallBackProc,
) {.exported.} =
  let
    blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    indexTyped = Quantity(uint64(index))

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getTransactionByBlockHashAndIndex(blockHashTyped, indexTyped)

proc eth_call(
    ctx: ptr Context,
    userData: pointer,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_call(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_createAccessList(
    ctx: ptr Context,
    userData: pointer,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_createAccessList(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_estimateGas(
    ctx: ptr Context,
    userData: pointer,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, userData, RET_DESER_ERROR, alloc(error))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_estimateGas(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_getTransactionByHash(
    ctx: ptr Context, userData: pointer, txHash: cstring, cb: CallBackProc
) {.exported.} =
  let txHashTyped = unpackArg($txHash, Hash32).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getTransactionByHash(txHashTyped)

proc eth_getBlockReceipts(
    ctx: ptr Context, userData: pointer, blockTag: cstring, cb: CallBackProc
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getBlockReceipts(blockTagTyped)

proc eth_getTransactionReceipt(
    ctx: ptr Context, userData: pointer, txHash: cstring, cb: CallBackProc
) {.exported.} =
  let txHashTyped = unpackArg($txHash, Hash32).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getTransactionReceipt(txHashTyped)

proc eth_getLogs(
    ctx: ptr Context, userData: pointer, filterOptions: cstring, cb: CallBackProc
) {.exported.} =
  let filterOptionsTyped = unpackArg($filterOptions, FilterOptions).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getLogs(filterOptionsTyped)

proc eth_newFilter(
    ctx: ptr Context, userData: pointer, filterOptions: cstring, cb: CallBackProc
) {.exported.} =
  let filterOptionsTyped = unpackArg($filterOptions, FilterOptions).valueOr:
    cb(ctx, userData, RET_DESER_ERROR, alloc(error))
    return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_newFilter(filterOptionsTyped)

proc eth_uninstallFilter(
    ctx: ptr Context, userData: pointer, filterId: cstring, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_uninstallFilter($filterId)

proc eth_getFilterLogs(
    ctx: ptr Context, userData: pointer, filterId: cstring, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getFilterLogs($filterId)

proc eth_getFilterChanges(
    ctx: ptr Context, userData: pointer, filterId: cstring, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_getFilterChanges($filterId)

proc eth_blobBaseFee(
    ctx: ptr Context, userData: pointer, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_blobBaseFee()

proc eth_gasPrice(ctx: ptr Context, userData: pointer, cb: CallBackProc) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_gasPrice()

proc eth_maxPriorityFeePerGas(
    ctx: ptr Context, userData: pointer, cb: CallBackProc
) {.exported.} =
  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_maxPriorityFeePerGas()

proc eth_sendRawTransaction(
    ctx: ptr Context, userData: pointer, txHexBytes: cstring, cb: CallBackProc
) {.exported.} =
  let txBytes =
    try:
      let temp = hexToSeqByte($txHexBytes)
      temp
    except ValueError as e:
      cb(ctx, userData, RET_DESER_ERROR, alloc(e.msg))
      return

  callbackToC(ctx, userData, cb):
    ctx.frontend.eth_sendRawTransaction(txBytes)

proc nvp_call(
    ctx: ptr Context,
    userData: pointer,
    name: cstring,
    params: cstring,
    cb: CallBackProc,
) {.exported.} =
  let parsedParams =
    try:
      let jsonNode = parseJson($params)
      jsonNode.getElems(@[])
    except CatchableError as e:
      cb(ctx, userData, RET_DESER_ERROR, alloc(e.msg))
      return

  template requireParams(n: int) =
    if parsedParams.len < n:
      cb(ctx, userData, RET_DESER_ERROR, alloc("parameters missing"))
      return

  case $name
  of "eth_blockNumber":
    requireParams(0)
    eth_blockNumber(ctx, userData, cb)
  of "eth_getBalance":
    requireParams(2)
    eth_getBalance(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
    )
  of "eth_getStorageAt":
    requireParams(3)
    eth_getStorageAt(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getStr().cstring,
      cb,
    )
  of "eth_getTransactionCount":
    requireParams(2)
    eth_getTransactionCount(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
    )
  of "eth_getCode":
    requireParams(2)
    eth_getCode(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
    )
  of "eth_getBlockByHash":
    requireParams(2)
    eth_getBlockByHash(
      ctx, userData, parsedParams[0].getStr().cstring, parsedParams[1].getBool(), cb
    )
  of "eth_getBlockByNumber":
    requireParams(2)
    eth_getBlockByNumber(
      ctx, userData, parsedParams[0].getStr().cstring, parsedParams[1].getBool(), cb
    )
  of "eth_getUncleCountByBlockNumber":
    requireParams(1)
    eth_getUncleCountByBlockNumber(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getUncleCountByBlockHash":
    requireParams(1)
    eth_getUncleCountByBlockHash(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getBlockTransactionCountByNumber":
    requireParams(1)
    eth_getBlockTransactionCountByNumber(
      ctx, userData, parsedParams[0].getStr().cstring, cb
    )
  of "eth_getBlockTransactionCountByHash":
    requireParams(1)
    eth_getBlockTransactionCountByHash(
      ctx, userData, parsedParams[0].getStr().cstring, cb
    )
  of "eth_getTransactionByBlockNumberAndIndex":
    requireParams(2)
    eth_getTransactionByBlockNumberAndIndex(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getBiggestInt().culonglong,
      cb,
    )
  of "eth_getTransactionByBlockHashAndIndex":
    requireParams(2)
    eth_getTransactionByBlockHashAndIndex(
      ctx,
      userData,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getBiggestInt().culonglong,
      cb,
    )
  of "eth_call":
    requireParams(3)
    eth_call(
      ctx,
      userData,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
    )
  of "eth_createAccessList":
    requireParams(3)
    eth_createAccessList(
      ctx,
      userData,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
    )
  of "eth_estimateGas":
    requireParams(3)
    eth_estimateGas(
      ctx,
      userData,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
    )
  of "eth_getTransactionByHash":
    requireParams(1)
    eth_getTransactionByHash(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getBlockReceipts":
    requireParams(1)
    eth_getBlockReceipts(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getTransactionReceipt":
    requireParams(1)
    eth_getTransactionReceipt(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getLogs":
    requireParams(1)
    eth_getLogs(ctx, userData, ($parsedParams[0]).cstring, cb)
  of "eth_newFilter":
    requireParams(1)
    eth_newFilter(ctx, userData, ($parsedParams[0]).cstring, cb)
  of "eth_uninstallFilter":
    requireParams(1)
    eth_uninstallFilter(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getFilterLogs":
    requireParams(1)
    eth_getFilterLogs(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_getFilterChanges":
    requireParams(1)
    eth_getFilterChanges(ctx, userData, parsedParams[0].getStr().cstring, cb)
  of "eth_blobBaseFee":
    requireParams(0)
    eth_blobBaseFee(ctx, userData, cb)
  of "eth_gasPrice":
    requireParams(0)
    eth_gasPrice(ctx, userData, cb)
  of "eth_maxPriorityFeePerGas":
    requireParams(0)
    eth_maxPriorityFeePerGas(ctx, userData, cb)
  of "eth_sendRawTransaction":
    requireParams(1)
    eth_sendRawTransaction(ctx, userData, parsedParams[0].getStr().cstring, cb)
  else:
    cb(ctx, userData, RET_DESER_ERROR, alloc("unknown method"))
