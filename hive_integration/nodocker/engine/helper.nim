import
  std/[typetraits, times],
  nimcrypto/sysrand,
  eth/[common, rlp, keys],
  json_rpc/[rpcclient],
  ../../../nimbus/transaction,
  ../../../nimbus/utils/utils,
  ../../../nimbus/rpc/execution_types,
  ./types

import eth/common/eth_types as common_eth_types
type
  Hash256 = common_eth_types.Hash256
  EthBlockHeader = common_eth_types.BlockHeader

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
    extraData*    : common.Blob
    baseFeePerGas*: UInt256
    blockHash*    : Hash256
    transactions* : seq[Transaction]
    withdrawals*  : Option[seq[Withdrawal]]
    blobGasUsed*  : Option[uint64]
    excessBlobGas*: Option[uint64]

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
    extraData*    : Option[common.Blob]
    baseFeePerGas*: Option[UInt256]
    blockHash*    : Option[Hash256]
    transactions* : Option[seq[Transaction]]
    withdrawals*  : Option[seq[Withdrawal]]
    blobGasUsed*  : Option[uint64]
    excessBlobGas*: Option[uint64]
    beaconRoot*   : Option[Hash256]
    removeWithdrawals*: bool

  InvalidPayloadField* = enum
    InvalidParentHash
    InvalidStateRoot
    InvalidReceiptsRoot
    InvalidNumber
    InvalidGasLimit
    InvalidGasUsed
    InvalidTimestamp
    InvalidPrevRandao
    RemoveTransaction
    InvalidTransactionSignature
    InvalidTransactionNonce
    InvalidTransactionGas
    InvalidTransactionGasPrice
    InvalidTransactionValue

  SignatureVal = object
    V: int64
    R: UInt256
    S: UInt256

  CustomTx = object
    nonce   : Option[AccountNonce]
    gasPrice: Option[GasInt]
    gasLimit: Option[GasInt]
    to      : Option[EthAddress]
    value   : Option[UInt256]
    data    : Option[seq[byte]]
    sig     : Option[SignatureVal]

proc customizePayload*(basePayload: ExecutableData, customData: CustomPayload): ExecutionPayload =
  let txs = if customData.transactions.isSome:
              customData.transactions.get
            else:
              basePayload.transactions
  let txRoot = calcTxRoot(txs)

  let wdRoot = if customData.withdrawals.isSome:
                 some(calcWithdrawalsRoot(customData.withdrawals.get))
               elif basePayload.withdrawals.isSome:
                 some(calcWithdrawalsRoot(basePayload.withdrawals.get))
               else:
                 none(Hash256)

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
    fee:           some(basePayload.baseFeePerGas),
    withdrawalsRoot: wdRoot,
    blobGasUsed:   basePayload.blobGasUsed,
    excessBlobGas: basePayload.excessBlobGas,
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

  if customData.blobGasUsed.isSome:
    customHeader.blobGasUsed = customData.blobGasUsed

  if customData.excessBlobGas.isSome:
    customHeader.excessBlobGas = customData.excessBlobGas

  if customData.beaconRoot.isSome:
    customHeader.parentBeaconBlockRoot = customData.beaconRoot

  # Return the new payload
  result = ExecutionPayload(
    parentHash:    w3Hash customHeader.parentHash,
    feeRecipient:  Web3Address customHeader.coinbase,
    stateRoot:     w3Hash customHeader.stateRoot,
    receiptsRoot:  w3Hash customHeader.receiptRoot,
    logsBloom:     Web3Bloom customHeader.bloom,
    prevRandao:    Web3PrevRandao customHeader.mixDigest.data,
    blockNumber:   Web3Quantity customHeader.blockNumber.truncate(uint64),
    gasLimit:      Web3Quantity customHeader.gasLimit,
    gasUsed:       Web3Quantity customHeader.gasUsed,
    timestamp:     Web3Quantity toUnix(customHeader.timestamp),
    extraData:     Web3ExtraData customHeader.extraData,
    baseFeePerGas: customHeader.baseFee,
    blockHash:     w3Hash customHeader.blockHash,
    blobGasUsed:   w3Qty customHeader.blobGasUsed,
    excessBlobGas: w3Qty customHeader.excessBlobGas,
  )

  for tx in txs:
    let txData = rlp.encode(tx)
    result.transactions.add TypedTransaction(txData)

  let wds = if customData.withdrawals.isSome:
              customData.withdrawals
            elif basePayload.withdrawals.isSome:
              basePayload.withdrawals
            else:
              none(seq[Withdrawal])

  if wds.isSome and customData.removeWithdrawals.not:
    result.withdrawals = some(w3Withdrawals(wds.get))

proc toExecutableData*(payload: ExecutionPayload): ExecutableData =
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
    blockHash     : hash256(payload.blockHash),
    blobGasUsed   : u64 payload.blobGasUsed,
    excessBlobGas : u64 payload.excessBlobGas,
  )

  for data in payload.transactions:
    let tx = rlp.decode(distinctBase data, Transaction)
    result.transactions.add tx

  if payload.withdrawals.isSome:
    result.withdrawals = some(withdrawals(payload.withdrawals.get))

proc customizePayload*(basePayload: ExecutionPayload, customData: CustomPayload): ExecutionPayload =
  customizePayload(basePayload.toExecutableData, customData)

proc customizeTx(baseTx: Transaction, vaultKey: PrivateKey, customTx: CustomTx): Transaction =
  # Create a modified transaction base, from the base transaction and customData mix
  var modTx = Transaction(
    txType  : TxLegacy,
    nonce   : baseTx.nonce,
    gasPrice: baseTx.gasPrice,
    gasLimit: baseTx.gasLimit,
    to      : baseTx.to,
    value   : baseTx.value,
    payload : baseTx.payload
   )

  if customTx.nonce.isSome:
    modTx.nonce = customTx.nonce.get

  if customTx.gasPrice.isSome:
    modTx.gasPrice = customTx.gasPrice.get

  if customTx.gasLimit.isSome:
    modTx.gasLimit = customTx.gasLimit.get

  if customTx.to.isSome:
    modTx.to = customTx.to

  if customTx.value.isSome:
    modTx.value = customTx.value.get

  if customTx.data.isSome:
    modTx.payload = customTx.data.get

  if customTx.sig.isSome:
    let sig = customTx.sig.get
    modTx.V = sig.V
    modTx.R = sig.R
    modTx.S = sig.S
    modTx
  else:
    # If a custom signature was not specified, simply sign the transaction again
    let chainId = baseTx.chainId
    signTransaction(modTx, vaultKey, chainId, eip155 = true)

proc modifyHash(x: Hash256): Hash256 =
  result = x
  result.data[^1] = byte(255 - x.data[^1].int)

proc generateInvalidPayload*(basePayload: ExecutableData,
                             payloadField: InvalidPayloadField,
                             vaultKey: PrivateKey): ExecutionPayload =

  var customPayload: CustomPayload

  case payloadField
  of InvalidParentHash:
    customPayload.parentHash = some(modifyHash(basePayload.parentHash))
  of InvalidStateRoot:
    customPayload.stateRoot = some(modifyHash(basePayload.stateRoot))
  of InvalidReceiptsRoot:
    customPayload.receiptsRoot = some(modifyHash(basePayload.receiptsRoot))
  of InvalidNumber:
    customPayload.number = some(basePayload.number - 1'u64)
  of InvalidGasLimit:
    customPayload.gasLimit = some(basePayload.gasLimit * 2)
  of InvalidGasUsed:
    customPayload.gasUsed = some(basePayload.gasUsed - 1)
  of InvalidTimestamp:
    customPayload.timestamp = some(basePayload.timestamp - 1.seconds)
  of InvalidPrevRandao:
    # This option potentially requires a transaction that uses the PREVRANDAO opcode.
    # Otherwise the payload will still be valid.
    var randomHash: Hash256
    doAssert randomBytes(randomHash.data) == 32
    customPayload.prevRandao = some(randomHash)
  of RemoveTransaction:
    let emptyTxs: seq[Transaction] = @[]
    customPayload.transactions = some(emptyTxs)
  of InvalidTransactionSignature,
    InvalidTransactionNonce,
    InvalidTransactionGas,
    InvalidTransactionGasPrice,
    InvalidTransactionValue:

    doAssert(basePayload.transactions.len != 0, "No transactions available for modification")

    var baseTx = basePayload.transactions[0]
    var customTx: CustomTx
    case payloadField
    of InvalidTransactionSignature:
      let sig = SignatureVal(
        V: baseTx.V,
        R: baseTx.R - 1.u256,
        S: baseTx.S
      )
      customTx.sig = some(sig)
    of InvalidTransactionNonce:
      customTx.nonce = some(baseTx.nonce - 1)
    of InvalidTransactionGas:
      customTx.gasLimit = some(0.GasInt)
    of InvalidTransactionGasPrice:
      customTx.gasPrice = some(0.GasInt)
    of InvalidTransactionValue:
      # Vault account initially has 0x123450000000000000000, so this value should overflow
      customTx.value = some(UInt256.fromHex("0x123450000000000000001"))
    else:
      discard

    let modTx = customizeTx(baseTx, vaultKey, customTx)
    customPayload.transactions = some(@[modTx])

  customizePayload(basePayload, customPayload)

proc generateInvalidPayload*(basePayload: ExecutionPayload,
                             payloadField: InvalidPayloadField,
                             vaultKey = default(PrivateKey)): ExecutionPayload =
  generateInvalidPayload(basePayload.toExecutableData, payloadField, vaultKey)

proc txInPayload*(payload: ExecutionPayload, txHash: Hash256): bool =
  for txBytes in payload.transactions:
    let currTx = rlp.decode(common.Blob txBytes, Transaction)
    if rlpHash(currTx) == txHash:
      return true
