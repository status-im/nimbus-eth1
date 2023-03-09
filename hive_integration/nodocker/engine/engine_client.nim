import
  std/[times, json, strutils],
  stew/byteutils,
  eth/[common, common/eth_types, rlp], chronos,
  web3/engine_api_types,
  json_rpc/[rpcclient, errors],
  ../../../tests/rpcclient/eth_api,
  ../../../premix/parser,
  ../../../nimbus/rpc/hexstrings,
  ../../../premix/parser

import web3/engine_api as web3_engine_api

type Hash256 = eth_types.Hash256

template wrapTry(body: untyped) =
  try:
    body
  except ValueError as e:
    return err(e.msg)
  except JsonRpcError as ex:
    return err(ex.msg)

template wrapTrySimpleRes(body: untyped) =
  wrapTry:
    let res = waitFor body
    return ok(res)

proc forkchoiceUpdatedV1*(client: RpcClient,
      update: ForkchoiceStateV1,
      payloadAttributes = none(PayloadAttributesV1)):
        Result[ForkchoiceUpdatedResponse, string] =
  wrapTrySimpleRes:
    client.engine_forkchoiceUpdatedV1(update, payloadAttributes)

proc getPayloadV1*(client: RpcClient, payloadId: PayloadID): Result[ExecutionPayloadV1, string] =
  wrapTrySimpleRes:
    client.engine_getPayloadV1(payloadId)

proc newPayloadV1*(client: RpcClient,
      payload: ExecutionPayloadV1):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV1(payload)

proc newPayloadV2*(client: RpcClient,
      payload: ExecutionPayloadV2):
        Result[PayloadStatusV1, string] =
  wrapTrySimpleRes:
    client.engine_newPayloadV2(payload)

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
  wrapTry:
    let res = waitFor client.eth_blockNumber()
    return ok(hexToInt(string res, uint64))

proc headerByNumber*(client: RpcClient, number: uint64, output: var common.BlockHeader): Result[void, string] =
  wrapTry:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, false)
    if res.isNone:
      return err("failed to get blockHeader: " & $number)
    output = toBlockHeader(res.get())
    return ok()

proc blockByNumber*(client: RpcClient, number: uint64, output: var common.EthBlock): Result[void, string] =
  wrapTry:
    let qty = encodeQuantity(number)
    let res = waitFor client.eth_getBlockByNumber(string qty, true)
    if res.isNone:
      return err("failed to get block: " & $number)
    let blk = res.get()
    output.header = toBlockHeader(blk)
    output.txs = toTransactions(blk.transactions)
    return ok()

proc headerByHash*(client: RpcClient, hash: Hash256, output: var common.BlockHeader): Result[void, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByHash(hash, false)
    if res.isNone:
      return err("failed to get block: " & hash.data.toHex)
    let blk = res.get()
    output = toBlockHeader(blk)
    return ok()

proc latestHeader*(client: RpcClient, output: var common.BlockHeader): Result[void, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber("latest", false)
    if res.isNone:
      return err("failed to get latest blockHeader")
    output = toBlockHeader(res.get())
    return ok()

proc latestBlock*(client: RpcClient, output: var common.EthBlock): Result[void, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber("latest", true)
    if res.isNone:
      return err("failed to get latest blockHeader")
    let blk = res.get()
    output.header = toBlockHeader(blk)
    output.txs = toTransactions(blk.transactions)
    return ok()

proc namedHeader*(client: RpcClient, name: string, output: var common.BlockHeader): Result[void, string] =
  wrapTry:
    let res = waitFor client.eth_getBlockByNumber(name, false)
    if res.isNone:
      return err("failed to get named blockHeader")
    output = toBlockHeader(res.get())
    return ok()

proc sendTransaction*(client: RpcClient, tx: common.Transaction): Result[void, string] =
  wrapTry:
    let encodedTx = rlp.encode(tx)
    let res = waitFor client.eth_sendRawTransaction(hexDataStr(encodedTx))
    let txHash = rlpHash(tx)
    let getHash = Hash256(data: hexToByteArray[32](string res))
    if txHash != getHash:
      return err("sendTransaction: tx hash mismatch")
    return ok()

proc balanceAt*(client: RpcClient, address: EthAddress): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getBalance(ethAddressStr(address), "latest")
    return ok(UInt256.fromHex(res.string))

proc txReceipt*(client: RpcClient, txHash: Hash256): Result[eth_api.ReceiptObject, string] =
  wrapTry:
    let res = waitFor client.eth_getTransactionReceipt(txHash)
    if res.isNone:
      return err("failed to get receipt: " & txHash.data.toHex)
    return ok(res.get)

proc toDataStr(slot: UInt256): HexDataStr =
  let hex = slot.toHex
  let prefix = if hex.len mod 2 == 0: "0x" else: "0x0"
  HexDataStr(prefix & hex)

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256): Result[UInt256, string] =
  wrapTry:
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), toDataStr(slot), "latest")
    return ok(UInt256.fromHex(res.string))

proc storageAt*(client: RpcClient, address: EthAddress, slot: UInt256, number: common.BlockNumber): Result[UInt256, string] =
  wrapTry:
    let tag = encodeQuantity(number)
    let res = waitFor client.eth_getStorageAt(ethAddressStr(address), toDataStr(slot), tag.string)
    return ok(UInt256.fromHex(res.string))

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


proc debugPrevRandaoTransaction*(client: RpcClient, tx: Transaction, expectedPrevRandao: Hash256): Result[void, string] =
  wrapTry:
    let hash = tx.rlpHash
    # we only interested in stack, disable all other elems
    let opts = %* {
      "disableStorage": true,
      "disableMemory": true,
      "disableState": true,
      "disableStateDiff": true
    }

    let res = waitFor client.call("debug_traceTransaction", %[%hash, opts])
    let structLogs = res["structLogs"]

    var prevRandaoFound = false
    for i, x in structLogs.elems:
      let op = x["op"].getStr
      if op != "DIFFICULTY": continue

      if i+1 >= structLogs.len:
        return err("No information after PREVRANDAO operation")

      prevRandaoFound = true
      let stack = structLogs[i+1]["stack"]
      if stack.len < 1:
        return err("Invalid stack after PREVRANDAO operation")

      let stackHash = Hash256(data: hextoByteArray[32](stack[0].getStr))
      if stackHash != expectedPrevRandao:
        return err("Invalid stack after PREVRANDAO operation $1 != $2" % [stackHash.data.toHex, expectedPrevRandao.data.toHex])

    if not prevRandaoFound:
      return err("PREVRANDAO opcode not found")

    return ok()
