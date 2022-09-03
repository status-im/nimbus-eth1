import
  json_rpc/[rpcclient], json, parser, httputils, strutils,
  eth/[common, rlp], chronicles, ../nimbus/[utils]

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
    methodName: string,
    params: JsonNode,
    client: Option[RpcClient] = none[RpcClient]()): JsonNode =
  if client.isSome():
    result = waitFor client.unsafeGet().call(methodName, params)
  else:
    var client = newRpcHttpClient()
    #client.httpMethod(MethodPost)
    waitFor client.connect("127.0.0.1", Port(8545), false)
    result = waitFor client.call(methodName, params)
    waitFor client.close()

proc requestBlockBody(
    n: JsonNode,
    blockNumber: BlockNumber,
    client: Option[RpcClient] = none[RpcClient]()): BlockBody =
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
      let uncle = request("eth_getUncleByBlockNumberAndIndex", %[%blockNumber, %idx], client)
      if uncle.kind == JNull:
        error "requested uncle not available", blockNumber=blockNumber, uncleIdx=i
        raise newException(ValueError, "Error when retrieving block uncles")
      result.uncles.add parseBlockHeader(uncle)

proc requestReceipts(
    n: JsonNode,
    client: Option[RpcClient] = none[RpcClient]()): seq[Receipt] =
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

proc requestTxTraces(
    n: JsonNode,
    client: Option[RpcClient] = none[RpcClient]()): JsonNode =
  result = newJArray()
  let txs = n["transactions"]
  if txs.len == 0: return
  for tx in txs:
    let txHash = tx["hash"]
    let txTrace = request("debug_traceTransaction", %[txHash], client)
    if txTrace.kind == JNull:
      error "requested trace not available", txHash=txHash
      raise newException(ValueError, "Error when retrieving transaction trace")
    result.add txTrace

proc requestHeader*(
    blockNumber: BlockNumber,
    client: Option[RpcClient] = none[RpcClient]()): JsonNode =
  result = request("eth_getBlockByNumber", %[%blockNumber.prefixHex, %true], client)
  if result.kind == JNull:
    error "requested block not available", blockNumber=blockNumber
    raise newException(ValueError, "Error when retrieving block header")

proc requestBlock*(
    blockNumber: BlockNumber,
    flags: set[DownloadFlags] = {},
    client: Option[RpcClient] = none[RpcClient]()): Block =
  let header = requestHeader(blockNumber, client)
  result.jsonData   = header
  result.header     = parseBlockHeader(header)
  result.body       = requestBlockBody(header, blockNumber, client)

  if DownloadTxTrace in flags:
    result.traces     = requestTxTraces(header, client)

  if DownloadReceipts in flags:
    result.receipts   = requestReceipts(header, client)
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
