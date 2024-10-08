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
  eth/common/blocks,
  eth/common/receipts,
  chronicles,
  ./parser

logScope:
  topics = "downloader"

type
  Block* = object
    header*: Header
    body*: BlockBody
    receipts*: seq[Receipt]
    jsonData*: JsonNode

proc request*(
    methodName: string,
    params: JsonNode,
    client: RpcClient): JsonNode =
  let res = waitFor client.call(methodName, params)
  JrpcConv.decode(res.string, JsonNode)

proc requestBlockBody(
    n: JsonNode,
    blockNumber: BlockNumber,
    client: RpcClient): BlockBody =
  let txs = n["transactions"]
  if txs.len > 0:
    result.transactions = newSeqOfCap[Transaction](txs.len)
    for tx in txs:
      let txn = parseTransaction(tx)
      validateTxSenderAndHash(tx, txn)
      result.transactions.add txn

  let uncles = n["uncles"]
  if uncles.len > 0:
    result.uncles = newSeqOfCap[Header](uncles.len)
    let blockNumber = blockNumber.to0xHex
    for i in 0 ..< uncles.len:
      let idx = i.to0xHex
      let uncle = request("eth_getUncleByBlockNumberAndIndex", %[%blockNumber, %idx], client)
      if uncle.kind == JNull:
        error "requested uncle not available", blockNumber=blockNumber, uncleIdx=i
        raise newException(ValueError, "Error when retrieving block uncles")
      result.uncles.add parseBlockHeader(uncle)

proc requestReceipts(
    n: JsonNode,
    client: RpcClient): seq[Receipt] =
  let txs = n["transactions"]
  if txs.len > 0:
    result = newSeqOfCap[Receipt](txs.len)
    for tx in txs:
      let txHash = tx["hash"]
      let rec = request("eth_getTransactionReceipt", %[txHash], client)
      if rec.kind == JNull:
        error "requested receipt not available", txHash=txHash
        raise newException(ValueError, "Error when retrieving block receipts")
      result.add parseReceipt(rec)

proc requestHeader*(
    blockNumber: BlockNumber,
    client: RpcClient): JsonNode =
  result = request("eth_getBlockByNumber", %[%blockNumber.to0xHex, %true], client)
  if result.kind == JNull:
    error "requested block not available", blockNumber=blockNumber
    raise newException(ValueError, "Error when retrieving block header")

proc requestBlock*(
    blockNumber: BlockNumber,
    client: RpcClient): Block =
  let header = requestHeader(blockNumber, client)
  result.jsonData   = header
  result.header     = parseBlockHeader(header)
  result.body       = requestBlockBody(header, blockNumber, client)
  result.receipts   = requestReceipts(header, client)
