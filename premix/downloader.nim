import
  json_rpc/[rpcclient], json, parser, httputils, strutils,
  eth/[common, rlp], chronicles, ../nimbus/[utils], nimcrypto

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

proc request*(methodName: string, params: JsonNode): JsonNode =
  var client = newRpcHttpClient()
  client.httpMethod(MethodPost)
  waitFor client.connect("localhost", Port(8545))
  var r = waitFor client.call(methodName, params)
  if r.error:
    result = newJNull()
  else:
    result = r.result
  waitFor client.close()

proc requestBlockBody(n: JsonNode, blockNumber: BlockNumber): BlockBody =
  let txs = n["transactions"]
  if txs.len > 0:
    result.transactions = newSeqOfCap[Transaction](txs.len)
    for tx in txs:
      let txn = parseTransaction(tx)
      result.transactions.add txn

  let uncles = n["uncles"]
  if uncles.len > 0:
    result.uncles = newSeqOfCap[BlockHeader](uncles.len)
    let blockNumber = blockNumber.prefixHex
    for i in 0 ..< uncles.len:
      let idx = i.prefixHex
      let uncle = request("eth_getUncleByBlockNumberAndIndex", %[%blockNumber, %idx])
      if uncle.kind == JNull:
        error "requested uncle not available", blockNumber=blockNumber, uncleIdx=i
        raise newException(ValueError, "Error when retrieving block uncles")
      result.uncles.add parseBlockHeader(uncle)

proc requestReceipts(n: JsonNode): seq[Receipt] =
  let txs = n["transactions"]
  if txs.len > 0:
    result = newSeqOfCap[Receipt](txs.len)
    for tx in txs:
      let txHash = tx["hash"]
      let rec = request("eth_getTransactionReceipt", %[txHash])
      if rec.kind == JNull:
        error "requested receipt not available", txHash=txHash
        raise newException(ValueError, "Error when retrieving block receipts")
      result.add parseReceipt(rec)

proc requestTxTraces(n: JsonNode): JsonNode =
  result = newJArray()
  let txs = n["transactions"]
  if txs.len == 0: return
  for tx in txs:
    let txHash = tx["hash"]
    let txTrace = request("debug_traceTransaction", %[txHash])
    if txTrace.kind == JNull:
      error "requested trace not available", txHash=txHash
      raise newException(ValueError, "Error when retrieving transaction trace")
    result.add txTrace

proc requestHeader*(blockNumber: BlockNumber): JsonNode =
  result = request("eth_getBlockByNumber", %[%blockNumber.prefixHex, %true])
  if result.kind == JNull:
    error "requested block not available", blockNumber=blockNumber
    raise newException(ValueError, "Error when retrieving block header")

proc requestBlock*(blockNumber: BlockNumber, flags: set[DownloadFlags] = {}): Block =
  let header = requestHeader(blockNumber)
  result.jsonData   = header
  result.header     = parseBlockHeader(header)
  result.body       = requestBlockBody(header, blockNumber)

  if DownloadTxTrace in flags:
    result.traces     = requestTxTraces(header)

  if DownloadReceipts in flags:
    result.receipts   = requestReceipts(header)
    let
      receiptRoot   = calcReceiptRoot(result.receipts).prefixHex
      receiptRootOK = result.header.receiptRoot.prefixHex
    if receiptRoot != receiptRootOK:
      debug "wrong receipt root", receiptRoot, receiptRootOK, blockNumber
      raise newException(ValueError, "Error when validating receipt root")

  if DownloadAndValidate in flags:
    let
      txRoot        = calcTxRoot(result.body.transactions).prefixHex
      txRootOK      = result.header.txRoot.prefixHex
      ommersHash    = rlpHash(result.body.uncles).prefixHex
      ommersHashOK  = result.header.ommersHash.prefixHex
      headerHash    = rlpHash(result.header).prefixHex
      headerHashOK  = header["hash"].getStr().toLowerAscii

    if txRoot != txRootOK:
      debug "wrong tx root", txRoot, txRootOK, blockNumber
      raise newException(ValueError, "Error when validating tx root")

    if ommersHash != ommersHashOK:
      debug "wrong ommers hash", ommersHash, ommersHashOK, blockNumber
      raise newException(ValueError, "Error when validating ommers hash")

    if headerHash != headerHashOK:
      debug "wrong header hash", headerHash, headerHashOK, blockNumber
      raise newException(ValueError, "Error when validating block header hash")
