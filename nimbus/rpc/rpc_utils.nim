# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import hexstrings, eth/[common, rlp, keys, trie/db], stew/byteutils, nimcrypto,
  ../db/db_chain, strutils, algorithm, options, times, json,
  ../constants, stint, hexstrings, rpc_types,
  ../utils, ../transaction,
  ../transaction/call_evm, ../forks

const
  defaultTag = "latest"

func toAddress*(value: EthAddressStr): EthAddress = hexToPaddedByteArray[20](value.string)

func toHash*(value: array[32, byte]): Hash256 {.inline.} =
  result.data = value

func toHash*(value: EthHashStr): Hash256 {.inline.} =
  result = hexToPaddedByteArray[32](value.string).toHash

func hexToInt*(s: string, T: typedesc[SomeInteger]): T =
  var i = 0
  if s[i] == '0' and (s[i+1] in {'x', 'X'}): inc(i, 2)
  if s.len - i > sizeof(T) * 2:
    raise newException(ValueError, "input hex too big for destination int")
  while i < s.len:
    result = result shl 4 or readHexChar(s[i]).T
    inc(i)

proc headerFromTag*(chain: BaseChainDB, blockTag: string): BlockHeader =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest": result = chain.getCanonicalHead()
  of "earliest": result = chain.getBlockHeader(GENESIS_BLOCK_NUMBER)
  of "safe": result = chain.safeHeader()
  of "finalized": result = chain.finalizedHeader()
  of "pending":
    #TODO: Implement get pending block
    raise newException(ValueError, "Pending tag not yet implemented")
  else:
    # Raises are trapped and wrapped in JSON when returned to the user.
    tag.validateHexQuantity
    let blockNum = stint.fromHex(UInt256, tag)
    result = chain.getBlockHeader(blockNum.toBlockNumber)

proc headerFromTag*(chain: BaseChainDB, blockTag: Option[string]): BlockHeader =
  if blockTag.isSome():
    return chain.headerFromTag(blockTag.unsafeGet())
  else:
    return chain.headerFromTag(defaultTag)

proc calculateMedianGasPrice*(chain: BaseChainDB): GasInt =
  var prices  = newSeqOfCap[GasInt](64)
  let header = chain.getCanonicalHead()
  for encodedTx in chain.getBlockTransactionData(header.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    prices.add(tx.gasPrice)

  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      let price = prices[middle].uint64 + prices[middle - 1].uint64
      result = (price div 2).GasInt
    else:
      result = prices[middle]

proc unsignedTx*(tx: TxSend, chain: BaseChainDB, defaultNonce: AccountNonce): Transaction =
  if tx.to.isSome:
    result.to = some(toAddress(tx.to.get))

  if tx.gas.isSome:
    result.gasLimit = hexToInt(tx.gas.get().string, GasInt)
  else:
    result.gasLimit = 90000.GasInt

  if tx.gasPrice.isSome:
    result.gasPrice = hexToInt(tx.gasPrice.get().string, GasInt)
  else:
    result.gasPrice = calculateMedianGasPrice(chain)

  if tx.value.isSome:
    result.value = UInt256.fromHex(tx.value.get().string)
  else:
    result.value = 0.u256

  if tx.nonce.isSome:
    result.nonce = hexToInt(tx.nonce.get().string, AccountNonce)
  else:
    result.nonce = defaultNonce

  result.payload = hexToSeqByte(tx.data.string)

template optionalAddress(src, dst: untyped) =
  if src.isSome:
    dst = some(toAddress(src.get))

template optionalGas(src, dst: untyped) =
  if src.isSome:
    dst = some(hexToInt(src.get.string, GasInt))

template optionalU256(src, dst: untyped) =
  if src.isSome:
    dst = some(UInt256.fromHex(src.get.string))

template optionalBytes(src, dst: untyped) =
  if src.isSome:
    dst = hexToSeqByte(src.get.string)

proc callData*(call: EthCall): RpcCallData =
  optionalAddress(call.source, result.source)
  optionalAddress(call.to, result.to)
  optionalGas(call.gas, result.gasLimit)
  optionalGas(call.gasPrice, result.gasPrice)
  optionalGas(call.maxFeePerGas, result.maxFee)
  optionalGas(call.maxPriorityFeePerGas, result.maxPriorityFee)
  optionalU256(call.value, result.value)
  optionalBytes(call.data, result.data)

proc populateTransactionObject*(tx: Transaction, header: BlockHeader, txIndex: int): TransactionObject =
  result.blockHash = some(header.hash)
  result.blockNumber = some(encodeQuantity(header.blockNumber))
  result.`from` = tx.getSender()
  result.gas = encodeQuantity(tx.gasLimit.uint64)
  result.gasPrice = encodeQuantity(tx.gasPrice.uint64)
  result.hash = tx.rlpHash
  result.input = tx.payload
  result.nonce = encodeQuantity(tx.nonce.uint64)
  result.to = some(tx.destination)
  result.transactionIndex = some(encodeQuantity(txIndex.uint64))
  result.value = encodeQuantity(tx.value)
  result.v = encodeQuantity(tx.V.uint)
  result.r = encodeQuantity(tx.R)
  result.s = encodeQuantity(tx.S)

proc populateBlockObject*(header: BlockHeader, chain: BaseChainDB, fullTx: bool, isUncle = false): BlockObject =
  let blockHash = header.blockHash

  result.number = some(encodeQuantity(header.blockNumber))
  result.hash = some(blockHash)
  result.parentHash = header.parentHash
  result.nonce = some(hexDataStr(header.nonce))
  result.sha3Uncles = header.ommersHash
  result.logsBloom = FixedBytes[256] header.bloom
  result.transactionsRoot = header.txRoot
  result.stateRoot = header.stateRoot
  result.receiptsRoot = header.receiptRoot
  result.miner = header.coinbase
  result.difficulty = encodeQuantity(header.difficulty)
  result.extraData = hexDataStr(header.extraData)
  result.mixHash = header.mixDigest

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  result.size = encodeQuantity(size.uint)

  result.gasLimit  = encodeQuantity(header.gasLimit.uint64)
  result.gasUsed   = encodeQuantity(header.gasUsed.uint64)
  result.timestamp = encodeQuantity(header.timestamp.toUnix.uint64)
  result.baseFeePerGas = if header.fee.isSome:
                           some(encodeQuantity(header.baseFee))
                         else:
                           none(HexQuantityStr)
  if not isUncle:
    result.totalDifficulty = encodeQuantity(chain.getScore(blockHash))
    result.uncles = chain.getUncleHashes(header)

    if fullTx:
      var i = 0
      for tx in chain.getBlockTransactions(header):
        result.transactions.add %(populateTransactionObject(tx, header, i))
        inc i
    else:
      for x in chain.getBlockTransactionHashes(header):
        result.transactions.add %(x)

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction, txIndex: int, header: BlockHeader, fork: Fork): ReceiptObject =
  result.transactionHash = tx.rlpHash
  result.transactionIndex = encodeQuantity(txIndex.uint)
  result.blockHash = header.hash
  result.blockNumber = encodeQuantity(header.blockNumber)
  result.`from` = tx.getSender()
  result.to = some(tx.destination)
  result.cumulativeGasUsed = encodeQuantity(receipt.cumulativeGasUsed.uint64)
  result.gasUsed = encodeQuantity(gasUsed.uint64)

  if tx.contractCreation:
    var sender: EthAddress
    if tx.getSender(sender):
      let contractAddress = generateAddress(sender, tx.nonce)
      result.contractAddress = some(contractAddress)

  result.logs = receipt.logs
  result.logsBloom = FixedBytes[256] receipt.bloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    result.root = some(receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    result.status = some(encodeQuantity(receipt.status.uint64))

  let normTx = eip1559TxNormalization(tx, header.baseFee.truncate(GasInt), fork)
  result.effectiveGasPrice = encodeQuantity(normTx.gasPrice.uint64)
