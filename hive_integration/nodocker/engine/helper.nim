import
  std/typetraits,
  test_env,
  eth/rlp

type
  ExecutableData* = object
    parentHash*   : Hash256
    feeRecipient* : EthAddress
    stateRoot*    : Hash256
    receiptsRoot* : Hash256
    logsBloom*    : BloomFilter
    prevRandao*   : Hash256
    number*       : uint64
    gasLimit*     : GasInt
    gasUsed*      : GasInt
    timestamp*    : EthTime
    extraData*    : Blob
    baseFeePerGas*: UInt256
    blockHash*    : Hash256
    transactions* : seq[Transaction]

  CustomPayload* = object
    parentHash*   : Option[Hash256]
    feeRecipient* : Option[EthAddress]
    stateRoot*    : Option[Hash256]
    receiptsRoot* : Option[Hash256]
    logsBloom*    : Option[BloomFilter]
    prevRandao*   : Option[Hash256]
    number*       : Option[uint64]
    gasLimit*     : Option[GasInt]
    gasUsed*      : Option[GasInt]
    timestamp*    : Option[EthTime]
    extraData*    : Option[Blob]
    baseFeePerGas*: Option[UInt256]
    blockHash*    : Option[Hash256]
    transactions* : Option[seq[Transaction]]

proc customizePayload*(basePayload: ExecutableData, customData: CustomPayload): ExecutionPayloadV1 =
  let txs = if customData.transactions.isSome:
              customData.transactions.get
            else:
              basePayload.transactions

  let txRoot = calcTxRoot(txs)

  var customHeader = EthBlockHeader(
    parentHash:    basePayload.parentHash,
    ommersHash:    EMPTY_UNCLE_HASH,
    coinbase:      basePayload.feeRecipient,
    stateRoot:     basePayload.stateRoot,
    txRoot:        txRoot,
    receiptRoot:   basePayload.receiptsRoot,
    bloom:         basePayload.logsBloom,
    difficulty:    0.u256,
    blockNumber:   basePayload.number.toBlockNumber,
    gasLimit:      basePayload.gasLimit,
    gasUsed:       basePayload.gasUsed,
    timestamp:     basePayload.timestamp,
    extraData:     basePayload.extraData,
    mixDigest:     basePayload.prevRandao,
    nonce:         default(BlockNonce),
    fee:           some(basePayload.baseFeePerGas)
  )

  # Overwrite custom information
  if customData.parentHash.isSome:
    customHeader.parentHash = customData.parentHash.get

  if customData.feeRecipient.isSome:
    customHeader.coinbase = customData.feeRecipient.get

  if customData.stateRoot.isSome:
    customHeader.stateRoot = customData.stateRoot.get

  if customData.receiptsRoot.isSome:
    customHeader.receiptRoot = customData.receiptsRoot.get

  if customData.logsBloom.isSome:
    customHeader.bloom = customData.logsBloom.get

  if customData.prevRandao.isSome:
    customHeader.mixDigest = customData.prevRandao.get

  if customData.number.isSome:
    customHeader.blockNumber = toBlockNumber(customData.number.get)

  if customData.gasLimit.isSome:
    customHeader.gasLimit = customData.gasLimit.get

  if customData.gasUsed.isSome:
    customHeader.gasUsed = customData.gasUsed.get

  if customData.timestamp.isSome:
    customHeader.timestamp = customData.timestamp.get

  if customData.extraData.isSome:
    customHeader.extraData = customData.extraData.get

  if customData.baseFeePerGas.isSome:
    customHeader.baseFee = customData.baseFeePerGas.get

  # Return the new payload
  result = ExecutionPayloadV1(
    parentHash:    Web3BlockHash customHeader.parentHash.data,
    feeRecipient:  Web3Address customHeader.coinbase,
    stateRoot:     Web3BlockHash customHeader.stateRoot.data,
    receiptsRoot:  Web3BlockHash customHeader.receiptRoot.data,
    logsBloom:     Web3Bloom customHeader.bloom,
    prevRandao:    Web3PrevRandao customHeader.mixDigest.data,
    blockNumber:   Web3Quantity customHeader.blockNumber.truncate(uint64),
    gasLimit:      Web3Quantity customHeader.gasLimit,
    gasUsed:       Web3Quantity customHeader.gasUsed,
    timestamp:     Web3Quantity toUnix(customHeader.timestamp),
    extraData:     Web3ExtraData customHeader.extraData,
    baseFeePerGas: customHeader.baseFee,
    blockHash:     Web3BlockHash customHeader.blockHash.data
  )

  for tx in txs:
    let txData = rlp.encode(tx)
    result.transactions.add TypedTransaction(txData)

proc hash256*(h: Web3BlockHash): Hash256 =
  Hash256(data: distinctBase h)

proc toExecutableData*(payload: ExecutionPayloadV1): ExecutableData =
  result = ExecutableData(
    parentHash    : hash256(payload.parentHash),
    feeRecipient  : distinctBase payload.feeRecipient,
    stateRoot     : hash256(payload.stateRoot),
    receiptsRoot  : hash256(payload.receiptsRoot),
    logsBloom     : distinctBase payload.logsBloom,
    prevRandao    : hash256(payload.prevRandao),
    number        : uint64 payload.blockNumber,
    gasLimit      : GasInt payload.gasLimit,
    gasUsed       : GasInt payload.gasUsed,
    timestamp     : fromUnix(int64 payload.timestamp),
    extraData     : distinctBase payload.extraData,
    baseFeePerGas : payload.baseFeePerGas,
    blockHash     : hash256(payload.blockHash)
  )

  for data in payload.transactions:
    let tx = rlp.decode(distinctBase data, Transaction)
    result.transactions.add tx
