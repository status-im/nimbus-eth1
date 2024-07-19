# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils],
  json_rpc/[rpcclient],
  httputils,
  eth/common,
  chronicles,
  ../nimbus/utils/utils,
  ./parser

logScope:
  topics = "downloader"

type
  Block* = object
    header*: BlockHeader
    body*: BlockBody
    traces*: JsonNode
    receipts*: seq[Receipt]
    jsonData*: JsonNode

  DownloadFlags* = enum
    DownloadReceipts
    DownloadTxTrace
    DownloadAndValidate

proc request*(
    methodName: string, params: JsonNode, client: Option[RpcClient] = none[RpcClient]()
): JsonNode =
  if client.isSome():
    let res = waitFor client.unsafeGet().call(methodName, params)
    result = JrpcConv.decode(res.string, JsonNode)
  else:
    var client = newRpcHttpClient()
    #client.httpMethod(MethodPost)
    waitFor client.connect("127.0.0.1", Port(8545), false)
    let res = waitFor client.call(methodName, params)
    result = JrpcConv.decode(res.string, JsonNode)
    waitFor client.close()

proc requestBlockBody(
    n: JsonNode, blockNumber: BlockNumber, client: Option[RpcClient] = none[RpcClient]()
): BlockBody =
  let txs = n["transactions"]
  if txs.len > 0:
    result.transactions = newSeqOfCap[Transaction](txs.len)
    for tx in txs:
      let txn = parseTransaction(tx)
      validateTxSenderAndHash(tx, txn)
      result.transactions.add txn

  let uncles = n["uncles"]
  if uncles.len > 0:
    result.uncles = newSeqOfCap[BlockHeader](uncles.len)
    let blockNumber = blockNumber.prefixHex
    for i in 0 ..< uncles.len:
      let idx = i.prefixHex
      let uncle =
        request("eth_getUncleByBlockNumberAndIndex", %[%blockNumber, %idx], client)
      if uncle.kind == JNull:
        error "requested uncle not available", blockNumber = blockNumber, uncleIdx = i
        raise newException(ValueError, "Error when retrieving block uncles")
      result.uncles.add parseBlockHeader(uncle)

proc requestReceipts(
    n: JsonNode, client: Option[RpcClient] = none[RpcClient]()
): seq[Receipt] =
  let txs = n["transactions"]
  if txs.len > 0:
    result = newSeqOfCap[Receipt](txs.len)
    for tx in txs:
      let txHash = tx["hash"]
      let rec = request("eth_getTransactionReceipt", %[txHash], client)
      if rec.kind == JNull:
        error "requested receipt not available", txHash = txHash
        raise newException(ValueError, "Error when retrieving block receipts")
      result.add parseReceipt(rec)

proc requestTxTraces(
    n: JsonNode, client: Option[RpcClient] = none[RpcClient]()
): JsonNode =
  result = newJArray()
  let txs = n["transactions"]
  if txs.len == 0:
    return
  for tx in txs:
    let txHash = tx["hash"]
    let txTrace = request("debug_traceTransaction", %[txHash], client)
    if txTrace.kind == JNull:
      error "requested trace not available", txHash = txHash
      raise newException(ValueError, "Error when retrieving transaction trace")
    result.add txTrace

proc requestHeader*(
    blockNumber: BlockNumber, client: Option[RpcClient] = none[RpcClient]()
): JsonNode =
  result = request("eth_getBlockByNumber", %[%blockNumber.prefixHex, %true], client)
  if result.kind == JNull:
    error "requested block not available", blockNumber = blockNumber
    raise newException(ValueError, "Error when retrieving block header")

proc requestBlock*(
    blockNumber: BlockNumber,
    flags: set[DownloadFlags] = {},
    client: Option[RpcClient] = none[RpcClient](),
): Block =
  let header = requestHeader(blockNumber, client)
  result.jsonData = header
  result.header = parseBlockHeader(header)
  result.body = requestBlockBody(header, blockNumber, client)

  if DownloadTxTrace in flags:
    result.traces = requestTxTraces(header, client)

  if DownloadReceipts in flags:
    result.receipts = requestReceipts(header, client)
    if DownloadAndValidate in flags:
      let
        receiptsRoot = calcReceiptsRoot(result.receipts).prefixHex
        receiptsRootOK = result.header.receiptsRoot.prefixHex
      if receiptsRoot != receiptsRootOK:
        debug "wrong receipt root", receiptsRoot, receiptsRootOK, blockNumber
        raise newException(ValueError, "Error when validating receipt root")

  if DownloadAndValidate in flags:
    let
      txRoot = calcTxRoot(result.body.transactions).prefixHex
      txRootOK = result.header.txRoot.prefixHex
      ommersHash = rlpHash(result.body.uncles).prefixHex
      ommersHashOK = result.header.ommersHash.prefixHex
      headerHash = rlpHash(result.header).prefixHex
      headerHashOK = header["hash"].getStr().toLowerAscii

    if txRoot != txRootOK:
      debug "wrong tx root", txRoot, txRootOK, blockNumber
      raise newException(ValueError, "Error when validating tx root")

    if ommersHash != ommersHashOK:
      debug "wrong ommers hash", ommersHash, ommersHashOK, blockNumber
      raise newException(ValueError, "Error when validating ommers hash")

    if headerHash != headerHashOK:
      debug "wrong header hash", headerHash, headerHashOK, blockNumber
      raise newException(ValueError, "Error when validating block header hash")
