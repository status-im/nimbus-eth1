# nimbus_verified_proxy
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  stew/byteutils,
  std/[json],
  beacon_chain/spec/[digest, network],
  beacon_chain/nimbus_binary_common,
  json_rpc/[jsonmarshal],
  web3/[eth_api_types, conversions],
  ../engine/types,
  ../nimbus_verified_proxy_conf,
  ./types,
  ./utils

{.pragma: exported, cdecl, exportc, dynlib, raises: [].}

template callbackToC(
    ctx: ptr Context, cb: CallBackProc, userData: pointer, asyncCall: untyped
) =
  inc ctx.pendingCalls
  let fut = asyncCall

  proc sendResult(_: pointer) {.gcsafe.} =
    dec ctx.pendingCalls
    let (status, response) =
      if fut.cancelled():
        (RET_CANCELLED, Json.encode(fut.error().msg))
      elif fut.failed():
        (RET_ERROR, Json.encode(fut.error().msg))
      else:
        let res = fut.value()
        if res.isErr():
          (RET_ERROR, $res.error.errType & ": " & res.error.errMsg)
        else:
          (RET_SUCCESS, Json.encode(res.get()))

    cb(ctx, status, alloc(response), userData)

  if fut.finished:
    sendResult(nil)
  else:
    fut.addCallback sendResult

proc eth_blockNumber(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_blockNumber()

proc eth_getBalance(
    ctx: ptr Context,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBalance(addressTyped, blockTagTyped)

proc eth_getStorageAt(
    ctx: ptr Context,
    address: cstring,
    slot: cstring,
    blockTag: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    slotTyped = unpackArg($slot, UInt256).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getStorageAt(addressTyped, slotTyped, blockTagTyped)

proc eth_getTransactionCount(
    ctx: ptr Context,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getTransactionCount(addressTyped, blockTagTyped)

proc eth_getCode(
    ctx: ptr Context,
    address: cstring,
    blockTag: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    addressTyped = unpackArg($address, Address).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getCode(addressTyped, blockTagTyped)

proc eth_getBlockByHash(
    ctx: ptr Context,
    blockHash: cstring,
    fullTransactions: bool,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBlockByHash(blockHashTyped, fullTransactions)

proc eth_getBlockByNumber(
    ctx: ptr Context,
    blockTag: cstring,
    fullTransactions: bool,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBlockByNumber(blockTagTyped, fullTransactions)

proc eth_getUncleCountByBlockNumber(
    ctx: ptr Context, blockTag: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getUncleCountByBlockNumber(blockTagTyped)

proc eth_getUncleCountByBlockHash(
    ctx: ptr Context, blockHash: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getUncleCountByBlockHash(blockHashTyped)

proc eth_getBlockTransactionCountByNumber(
    ctx: ptr Context, blockTag: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBlockTransactionCountByNumber(blockTagTyped)

proc eth_getBlockTransactionCountByHash(
    ctx: ptr Context, blockHash: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBlockTransactionCountByHash(blockHashTyped)

proc eth_getTransactionByBlockNumberAndIndex(
    ctx: ptr Context,
    blockTag: cstring,
    index: culonglong,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    indexTyped = Quantity(uint64(index))

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getTransactionByBlockNumberAndIndex(blockTagTyped, indexTyped)

proc eth_getTransactionByBlockHashAndIndex(
    ctx: ptr Context,
    blockHash: cstring,
    index: culonglong,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    blockHashTyped = unpackArg($blockHash, Hash32).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    indexTyped = Quantity(uint64(index))

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getTransactionByBlockHashAndIndex(blockHashTyped, indexTyped)

proc eth_call(
    ctx: ptr Context,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_call(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_createAccessList(
    ctx: ptr Context,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_createAccessList(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_estimateGas(
    ctx: ptr Context,
    txArgs: cstring,
    blockTag: cstring,
    optimisticStateFetch: bool,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    txArgsTyped = unpackArg($txArgs, TransactionArgs).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

    blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_estimateGas(txArgsTyped, blockTagTyped, optimisticStateFetch)

proc eth_getTransactionByHash(
    ctx: ptr Context, txHash: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let txHashTyped = unpackArg($txHash, Hash32).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getTransactionByHash(txHashTyped)

proc eth_getBlockReceipts(
    ctx: ptr Context, blockTag: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let blockTagTyped = unpackArg($blockTag, BlockTag).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getBlockReceipts(blockTagTyped)

proc eth_getTransactionReceipt(
    ctx: ptr Context, txHash: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let txHashTyped = unpackArg($txHash, Hash32).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getTransactionReceipt(txHashTyped)

proc eth_getLogs(
    ctx: ptr Context, filterOptions: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let filterOptionsTyped = unpackArg($filterOptions, FilterOptions).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getLogs(filterOptionsTyped)

proc eth_newFilter(
    ctx: ptr Context, filterOptions: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let filterOptionsTyped = unpackArg($filterOptions, FilterOptions).valueOr:
    cb(ctx, RET_DESER_ERROR, alloc(error), userData)
    return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_newFilter(filterOptionsTyped)

proc eth_uninstallFilter(
    ctx: ptr Context, filterId: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_uninstallFilter($filterId)

proc eth_getFilterLogs(
    ctx: ptr Context, filterId: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getFilterLogs($filterId)

proc eth_getFilterChanges(
    ctx: ptr Context, filterId: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_getFilterChanges($filterId)

proc eth_blobBaseFee(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_blobBaseFee()

proc eth_gasPrice(ctx: ptr Context, cb: CallBackProc, userData: pointer) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_gasPrice()

proc eth_maxPriorityFeePerGas(
    ctx: ptr Context, cb: CallBackProc, userData: pointer
) {.exported.} =
  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_maxPriorityFeePerGas()

proc eth_feeHistory(
    ctx: ptr Context,
    blockCount: culonglong,
    newestBlock: cstring,
    rewardPercentiles: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let
    blockCountTyped = Quantity(uint64(blockCount))
    newestBlockTyped = unpackArg($newestBlock, BlockTag).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return
    rewardPercentilesTyped = unpackArg($rewardPercentiles, seq[int]).valueOr:
      cb(ctx, RET_DESER_ERROR, alloc(error), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_feeHistory(
      blockCountTyped, newestBlockTyped, rewardPercentilesTyped
    )

proc eth_sendRawTransaction(
    ctx: ptr Context, txHexBytes: cstring, cb: CallBackProc, userData: pointer
) {.exported.} =
  let txBytes =
    try:
      let temp = hexToSeqByte($txHexBytes)
      temp
    except ValueError as e:
      cb(ctx, RET_DESER_ERROR, alloc(e.msg), userData)
      return

  callbackToC(ctx, cb, userData):
    ctx.frontend.eth_sendRawTransaction(txBytes)

proc proxyCall(
    ctx: ptr Context,
    name: cstring,
    params: cstring,
    cb: CallBackProc,
    userData: pointer,
) {.exported.} =
  let parsedParams =
    try:
      let jsonNode = parseJson($params)
      jsonNode.getElems(@[])
    except CatchableError as e:
      cb(ctx, RET_DESER_ERROR, alloc(e.msg), userData)
      return

  template requireParams(n: int) =
    if parsedParams.len < n:
      cb(ctx, RET_DESER_ERROR, alloc("parameters missing"), userData)
      return

  case $name
  of "eth_blockNumber":
    requireParams(0)
    eth_blockNumber(ctx, cb, userData)
  of "eth_getBalance":
    requireParams(2)
    eth_getBalance(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
      userData,
    )
  of "eth_getStorageAt":
    requireParams(3)
    eth_getStorageAt(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getStr().cstring,
      cb,
      userData,
    )
  of "eth_getTransactionCount":
    requireParams(2)
    eth_getTransactionCount(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
      userData,
    )
  of "eth_getCode":
    requireParams(2)
    eth_getCode(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getStr().cstring,
      cb,
      userData,
    )
  of "eth_getBlockByHash":
    requireParams(2)
    eth_getBlockByHash(
      ctx, parsedParams[0].getStr().cstring, parsedParams[1].getBool(), cb, userData
    )
  of "eth_getBlockByNumber":
    requireParams(2)
    eth_getBlockByNumber(
      ctx, parsedParams[0].getStr().cstring, parsedParams[1].getBool(), cb, userData
    )
  of "eth_getUncleCountByBlockNumber":
    requireParams(1)
    eth_getUncleCountByBlockNumber(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getUncleCountByBlockHash":
    requireParams(1)
    eth_getUncleCountByBlockHash(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getBlockTransactionCountByNumber":
    requireParams(1)
    eth_getBlockTransactionCountByNumber(
      ctx, parsedParams[0].getStr().cstring, cb, userData
    )
  of "eth_getBlockTransactionCountByHash":
    requireParams(1)
    eth_getBlockTransactionCountByHash(
      ctx, parsedParams[0].getStr().cstring, cb, userData
    )
  of "eth_getTransactionByBlockNumberAndIndex":
    requireParams(2)
    eth_getTransactionByBlockNumberAndIndex(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getBiggestInt().culonglong,
      cb,
      userData,
    )
  of "eth_getTransactionByBlockHashAndIndex":
    requireParams(2)
    eth_getTransactionByBlockHashAndIndex(
      ctx,
      parsedParams[0].getStr().cstring,
      parsedParams[1].getBiggestInt().culonglong,
      cb,
      userData,
    )
  of "eth_call":
    requireParams(3)
    eth_call(
      ctx,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
      userData,
    )
  of "eth_createAccessList":
    requireParams(3)
    eth_createAccessList(
      ctx,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
      userData,
    )
  of "eth_estimateGas":
    requireParams(3)
    eth_estimateGas(
      ctx,
      ($parsedParams[0]).cstring,
      parsedParams[1].getStr().cstring,
      parsedParams[2].getBool(),
      cb,
      userData,
    )
  of "eth_getTransactionByHash":
    requireParams(1)
    eth_getTransactionByHash(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getBlockReceipts":
    requireParams(1)
    eth_getBlockReceipts(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getTransactionReceipt":
    requireParams(1)
    eth_getTransactionReceipt(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getLogs":
    requireParams(1)
    eth_getLogs(ctx, ($parsedParams[0]).cstring, cb, userData)
  of "eth_newFilter":
    requireParams(1)
    eth_newFilter(ctx, ($parsedParams[0]).cstring, cb, userData)
  of "eth_uninstallFilter":
    requireParams(1)
    eth_uninstallFilter(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getFilterLogs":
    requireParams(1)
    eth_getFilterLogs(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_getFilterChanges":
    requireParams(1)
    eth_getFilterChanges(ctx, parsedParams[0].getStr().cstring, cb, userData)
  of "eth_blobBaseFee":
    requireParams(0)
    eth_blobBaseFee(ctx, cb, userData)
  of "eth_gasPrice":
    requireParams(0)
    eth_gasPrice(ctx, cb, userData)
  of "eth_maxPriorityFeePerGas":
    requireParams(0)
    eth_maxPriorityFeePerGas(ctx, cb, userData)
  of "eth_feeHistory":
    requireParams(3)
    eth_feeHistory(
      ctx,
      parsedParams[0].getBiggestInt().culonglong,
      parsedParams[1].getStr().cstring,
      ($parsedParams[2]).cstring,
      cb,
      userData,
    )
  of "eth_sendRawTransaction":
    requireParams(1)
    eth_sendRawTransaction(ctx, parsedParams[0].getStr().cstring, cb, userData)
  else:
    cb(ctx, RET_DESER_ERROR, alloc("unknown method"), userData)
