import
  std/[times, json],
  stew/byteutils,
  eth/[common, rlp], chronos,
  web3/engine_api_types,
  json_rpc/rpcclient,
  ../../../tests/rpcclient/eth_api,
  ../../../premix/parser,
  ../../../nimbus/rpc/hexstrings,
  ../../../premix/parser

import web3/engine_api as web3_engine_api

proc forkchoiceUpdatedV1*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = none(PayloadAttributesV1)):
        Result[ForkchoiceUpdatedResponse, string] =
  try:
    let res = waitFor client.engine_forkchoiceUpdatedV1(update, payloadAttributes)
    return ok(res)
  except ValueError as e:
    return err(e.msg)

proc getPayloadV1*(client: RpcClient, payloadId: PayloadID): Result[ExecutionPayloadV1, string] =
  try:
    let res = waitFor client.engine_getPayloadV1(payloadId)
    return ok(res)
  except ValueError as e:
    return err(e.msg)

proc newPayloadV1*(client: RpcClient,
      payload: ExecutionPayloadV1):
        Result[PayloadStatusV1, string] =
  try:
    let res = waitFor client.engine_newPayloadV1(payload)
    return ok(res)
  except ValueError as e:
    return err(e.msg)

proc toBlockNumber(n: Option[HexQuantityStr]): common.BlockNumber =
  if n.isNone:
    return 0.toBlockNumber
  toBlockNumber(hexToInt(string n.get, uint64))

proc toBlockNonce(n: Option[HexDataStr]): common.BlockNonce =
  if n.isNone:
    return default(BlockNonce)
  hexToByteArray(string n.get, result)

proc toBaseFeePerGas(n: Option[HexQuantityStr]): Option[UInt256] =
  if n.isNone:
    return none(UInt256)
  some(UInt256.fromHex(string n.get))

proc toBlockHeader(bc: eth_api.BlockObject): common.BlockHeader =
  common.BlockHeader(
    blockNumber: toBlockNumber(bc.number),
    parentHash : bc.parentHash,
    nonce      : toBlockNonce(bc.nonce),
    ommersHash : bc.sha3Uncles,
    bloom      : BloomFilter bc.logsBloom,
    txRoot     : bc.transactionsRoot,
    stateRoot  : bc.stateRoot,
    receiptRoot: bc.receiptsRoot,
    coinbase   : bc.miner,
    difficulty : UInt256.fromHex(string bc.difficulty),
    extraData  : hexToSeqByte(string bc.extraData),
    mixDigest  : bc.mixHash,
    gasLimit   : hexToInt(string bc.gasLimit, GasInt),
    gasUsed    : hexToInt(string bc.gasUsed, GasInt),
    timestamp  : initTime(hexToInt(string bc.timestamp, int64), 0),
    fee        : toBaseFeePerGas(bc.baseFeePerGas)
  )

proc toTransactions(txs: openArray[JsonNode]): seq[Transaction] =
  for x in txs:
    result.add parseTransaction(x)

proc waitForTTD*(client: RpcClient,
      ttd: DifficultyInt): Future[(common.BlockHeader, bool)] {.async.} =
  let period = chronos.seconds(5)
  var loop = 0
  var emptyHeader: common.BlockHeader
  while loop < 5:
    let res = await client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return (emptyHeader, false)
    let bc = res.get()
    if hexToInt(string bc.totalDifficulty, int64).u256 >= ttd:
      return (toBlockHeader(bc), true)

    await sleepAsync(period)
    inc loop

  return (emptyHeader, false)

proc blockNumber*(client: RpcClient): Result[uint64, string] =
  try:
    let res = waitFor client.eth_blockNumber()
    return ok(hexToInt(string res, uint64))
  except ValueError as e:
    return err(e.msg)

proc headerByNumber*(client: RpcClient, number: uint64, output: var common.BlockHeader): Result[void, string] =
  try:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, false)
    if res.isNone:
      return err("failed to get blockHeader: " & $number)
    output = toBlockHeader(res.get())
    return ok()
  except ValueError as e:
    return err(e.msg)

proc blockByNumber*(client: RpcClient, number: uint64, output: var common.EthBlock): Result[void, string] =
  try:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, true)
    if res.isNone:
      return err("failed to get block: " & $number)
    let blk = res.get()
    output.header = toBlockHeader(blk)
    output.txs = toTransactions(blk.transactions)
    return ok()
  except ValueError as e:
    return err(e.msg)

proc headerByHash*(client: RpcClient, hash: Hash256, output: var common.BlockHeader): Result[void, string] =
  try:
    let res = waitFor client.eth_getBlockByHash(hash, false)
    if res.isNone:
      return err("failed to get block: " & hash.data.toHex)
    let blk = res.get()
    output = toBlockHeader(blk)
    return ok()
  except ValueError as e:
    return err(e.msg)

proc latestHeader*(client: RpcClient, output: var common.BlockHeader): Result[void, string] =
  try:
    let res = waitFor client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return err("failed to get latest blockHeader")
    output = toBlockHeader(res.get())
    return ok()
  except ValueError as e:
    return err(e.msg)

proc latestBlock*(client: RpcClient, output: var common.EthBlock): Result[void, string] =
  try:
    let res = waitFor client.eth_getBlockByNumber("latest", true)
    if res.isNone:
      return err("failed to get latest blockHeader")
    let blk = res.get()
    output.header = toBlockHeader(blk)
    output.txs = toTransactions(blk.transactions)
    return ok()
  except ValueError as e:
    return err(e.msg)

proc sendTransaction*(client: RpcClient, tx: common.Transaction): Result[void, string] =
  try:
    let encodedTx = rlp.encode(tx)
    let res = waitFor client.eth_sendRawTransaction(hexDataStr(encodedTx))
    let txHash = rlpHash(tx)
    let getHash = Hash256(data: hexToByteArray[32](string res))
    if txHash != getHash:
      return err("sendTransaction: tx hash mismatch")
    return ok()
  except ValueError as e:
    return err(e.msg)

proc balanceAt*(client: RpcClient, address: EthAddress): Result[UInt256, string] =
  try:
    let res = waitFor client.eth_getBalance(ethAddressStr(address), "latest")
    return ok(UInt256.fromHex(res.string))
  except ValueError as e:
    return err(e.msg)

proc txReceipt*(client: RpcClient, txHash: Hash256): Result[eth_api.ReceiptObject, string] =
  try:
    let res = waitFor client.eth_getTransactionReceipt(txHash)
    if res.isNone:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(res.get)
  except ValueError as e:
    return err(e.msg)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256): Result[UInt256, string] =
  try:
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), encodeQuantity(slot), "latest")
    return ok(UInt256.fromHex(res.string))
  except ValueError as e:
    return err(e.msg)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256, number: common.BlockNumber): Result[UInt256, string] =
  try:
    let tag = encodeQuantity(number)
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), encodeQuantity(slot), tag.string)
    return ok(UInt256.fromHex(res.string))
  except ValueError as e:
    return err(e.msg)

proc verifyPoWProgress*(client: RpcClient, lastBlockHash: Hash256): Future[Result[void, string]] {.async.} =
  let res = await client.eth_getBlockByHash(lastBlockHash, false)
  if res.isNone:
    return err("cannot get block by hash " & lastBlockHash.data.toHex)

  let header = res.get()
  let number = toBlockNumber(header.number)

  let period = chronos.seconds(3)
  var loop = 0
  while loop < 5:
    let res = await client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return err("cannot get latest block")

    # Chain has progressed, check that the next block is also PoW
    # Difficulty must NOT be zero
    let bc = res.get()
    let diff = hexToInt(string bc.difficulty, int64)
    if diff == 0:
      return err("Expected PoW chain to progress in PoW mode, but following block difficulty: " & $diff)

    if toBlockNumber(bc.number) > number:
      return ok()

    await sleepAsync(period)
    inc loop

  return err("verify PoW Progress timeout")
