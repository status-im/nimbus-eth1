# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[options, strutils, typetraits],
  stew/byteutils,
  ./blobs,
  ../types,
  ../tx_sender,
  ../../../../nimbus/constants,
  ../../../../nimbus/utils/utils,
  ../../../../nimbus/common as nimbus_common,
  ../../../../nimbus/beacon/web3_eth_conv,
  ../../../../nimbus/beacon/payload_conv,
  web3/execution_types

type
  EngineAPIVersionResolver* = ref object of RootRef
    com: CommonRef

method setEngineAPIVersionResolver*(cust: EngineAPIVersionResolver, v: CommonRef) {.base, gcsafe.} =
  cust.com = v

method forkchoiceUpdatedVersion*(cust: EngineAPIVersionResolver,
  headTimestamp: uint64, payloadAttributesTimestamp: Opt[uint64] = Opt.none(uint64)): Version {.base, gcsafe.} =
  let ts = if payloadAttributesTimestamp.isNone: headTimestamp.EthTime
           else: payloadAttributesTimestamp.get().EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

method newPayloadVersion*(cust: EngineAPIVersionResolver, timestamp: uint64): Version {.base, gcsafe.} =
  let ts = timestamp.EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

method getPayloadVersion*(cust: EngineAPIVersionResolver, timestamp: uint64): Version {.base, gcsafe.} =
  let ts = timestamp.EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

type
  GetPayloadCustomizer* = ref object of EngineAPIVersionResolver

method getPayloadID*(cust: GetPayloadCustomizer,
         basePayloadID: PayloadID): PayloadID {.base, gcsafe.} =
  doAssert(false, "getPayloadID unimplemented")

method getExpectedError*(cust: GetPayloadCustomizer): int {.base, gcsafe.} =
  doAssert(false, "getExpectedError unimplemented")

type
  BaseGetPayloadCustomizer* = ref object of GetPayloadCustomizer
    customPayloadID*: Opt[PayloadID]
    expectedError*  : int

method getPayloadID(cust: BaseGetPayloadCustomizer,
         basePayloadID: PayloadID): PayloadID =
  if cust.customPayloadID.isSome:
    return cust.customPayloadID.get
  return basePayloadID

method getExpectedError(cust: BaseGetPayloadCustomizer): int =
  cust.expectedError

type
  UpgradeGetPayloadVersion* = ref object of BaseGetPayloadCustomizer

method getPayloadVersion(cust: UpgradeGetPayloadVersion, timestamp: uint64): Version =
  let version = procCall getPayloadVersion(cust.GetPayloadCustomizer, timestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

type
  DowngradeGetPayloadVersion* = ref object of BaseGetPayloadCustomizer

method getPayloadVersion(cust: DowngradeGetPayloadVersion, timestamp: uint64): Version =
  let version = procCall getPayloadVersion(cust.GetPayloadCustomizer, timestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

type
  PayloadAttributesCustomizer* = ref object of BaseGetPayloadCustomizer

method getPayloadAttributes*(cust: PayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes {.base, gcsafe.} =
  doAssert(false, "getPayloadAttributes unimplemented")

type
  BasePayloadAttributesCustomizer* = ref object of PayloadAttributesCustomizer
    timestamp*             : Opt[uint64]
    prevRandao*            : Opt[common.Bytes32]
    suggestedFeeRecipient* : Opt[common.EthAddress]
    withdrawals*           : Opt[seq[Withdrawal]]
    removeWithdrawals*     : bool
    beaconRoot*            : Opt[common.Hash256]
    removeBeaconRoot*      : bool

method getPayloadAttributes(cust: BasePayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = PayloadAttributes(
    timestamp:             basePayloadAttributes.timestamp,
    prevRandao:            basePayloadAttributes.prevRandao,
    suggestedFeeRecipient: basePayloadAttributes.suggestedFeeRecipient,
    withdrawals:           basePayloadAttributes.withdrawals,
    parentBeaconBlockRoot: basePayloadAttributes.parentBeaconBlockRoot,
  )

  if cust.timestamp.isSome:
    customPayloadAttributes.timestamp = w3Qty cust.timestamp.get

  if cust.prevRandao.isSome:
    customPayloadAttributes.prevRandao = cust.prevRandao.get

  if cust.suggestedFeeRecipient.isSome:
    customPayloadAttributes.suggestedFeeRecipient = w3Addr cust.suggestedFeeRecipient.get

  if cust.removeWithdrawals:
    customPayloadAttributes.withdrawals = Opt.none(seq[WithdrawalV1])
  elif cust.withdrawals.isSome:
    customPayloadAttributes.withdrawals = w3Withdrawals cust.withdrawals

  if cust.removeBeaconRoot:
    customPayloadAttributes.parentBeaconBlockRoot = Opt.none(Web3Hash)
  elif cust.beaconRoot.isSome:
    customPayloadAttributes.parentBeaconBlockRoot = w3Hash cust.beaconRoot

  return customPayloadAttributes

type
  ForkchoiceUpdatedCustomizer* = ref object of BasePayloadAttributesCustomizer

method getForkchoiceState*(cust: ForkchoiceUpdatedCustomizer,
  baseForkchoiceUpdate: ForkchoiceStateV1): ForkchoiceStateV1 {.base, gcsafe.} =
  doAssert(false, "getForkchoiceState unimplemented")

method getExpectInvalidStatus*(cust: ForkchoiceUpdatedCustomizer): bool {.base, gcsafe.} =
  doAssert(false, "getExpectInvalidStatus unimplemented")

# Customizer that makes no modifications to the forkchoice directive call.
# Used as base to other customizers.
type
  BaseForkchoiceUpdatedCustomizer* = ref object of ForkchoiceUpdatedCustomizer
    expectInvalidStatus*: bool

method getPayloadAttributes(cust: BaseForkchoiceUpdatedCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = procCall getPayloadAttributes(cust.BasePayloadAttributesCustomizer, basePayloadAttributes)
  return customPayloadAttributes

method getForkchoiceState(cust: BaseForkchoiceUpdatedCustomizer, baseForkchoiceUpdate: ForkchoiceStateV1): ForkchoiceStateV1 =
  return baseForkchoiceUpdate

method getExpectInvalidStatus(cust: BaseForkchoiceUpdatedCustomizer): bool =
  return cust.expectInvalidStatus

# Customizer that upgrades the version of the forkchoice directive call to the next version.
type
  UpgradeForkchoiceUpdatedVersion* = ref object of BaseForkchoiceUpdatedCustomizer

method forkchoiceUpdatedVersion(cust: UpgradeForkchoiceUpdatedVersion, headTimestamp:
                                uint64, payloadAttributesTimestamp: Opt[uint64] = Opt.none(uint64)): Version =
  let version = procCall forkchoiceUpdatedVersion(EngineAPIVersionResolver(cust), headTimestamp, payloadAttributesTimestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

# Customizer that downgrades the version of the forkchoice directive call to the previous version.
type
  DowngradeForkchoiceUpdatedVersion* = ref object of BaseForkchoiceUpdatedCustomizer

method forkchoiceUpdatedVersion(cust: DowngradeForkchoiceUpdatedVersion, headTimestamp: uint64,
                                payloadAttributesTimestamp: Opt[uint64] = Opt.none(uint64)): Version =
  let version = procCall forkchoiceUpdatedVersion(EngineAPIVersionResolver(cust), headTimestamp, payloadAttributesTimestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

type
  TimestampDeltaPayloadAttributesCustomizer* = ref object of BaseForkchoiceUpdatedCustomizer
    timestampDelta*: int

method getPayloadAttributes(cust: TimestampDeltaPayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = procCall getPayloadAttributes(cust.BasePayloadAttributesCustomizer, basePayloadAttributes)
  customPayloadAttributes.timestamp = w3Qty(customPayloadAttributes.timestamp, cust.timestampDelta)
  return customPayloadAttributes

type
  VersionedHashesCustomizer* = ref object of RootRef
    blobs*: Opt[seq[BlobID]]
    hashVersions*: seq[byte]

method getVersionedHashes*(cust: VersionedHashesCustomizer,
                           baseVersionedHashes: openArray[common.Hash256]): Opt[seq[common.Hash256]] {.base, gcsafe.} =
  if cust.blobs.isNone:
    return Opt.none(seq[common.Hash256])

  let blobs = cust.blobs.get
  var v = newSeq[common.Hash256](blobs.len)

  var version: byte
  for i, blobID in blobs:
    if cust.hashVersions.len > i:
      version = cust.hashVersions[i]
    v[i] = blobID.getVersionedHash(version)
  Opt.some(v)

method description*(cust: VersionedHashesCustomizer): string {.base, gcsafe.} =
  result = "VersionedHashes: "
  if cust.blobs.isSome:
    for x in cust.blobs.get:
      result.add x.toHex

  if cust.hashVersions.len > 0:
    result.add " with versions "
    result.add cust.hashVersions.toHex

type
  IncreaseVersionVersionedHashes* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: IncreaseVersionVersionedHashes,
                          baseVersionedHashes: openArray[common.Hash256]): Opt[seq[common.Hash256]] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  var v = newSeq[common.Hash256](baseVersionedHashes.len)
  for i, h in baseVersionedHashes:
    v[i] = h
    v[i].data[0] = v[i].data[0] + 1
  Opt.some(v)

type
  CorruptVersionedHashes* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: CorruptVersionedHashes,
                          baseVersionedHashes: openArray[common.Hash256]): Opt[seq[common.Hash256]] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  var v = newSeq[common.Hash256](baseVersionedHashes.len)
  for i, h in baseVersionedHashes:
    v[i] = h
    v[i].data[h.data.len-1] = v[i].data[h.data.len-1] + 1
  Opt.some(v)

type
  RemoveVersionedHash* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: RemoveVersionedHash,
                          baseVersionedHashes: openArray[common.Hash256]): Opt[seq[common.Hash256]] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  var v = newSeq[common.Hash256](baseVersionedHashes.len - 1)
  for i, h in baseVersionedHashes:
    if i < baseVersionedHashes.len-1:
      v[i] = h
      v[i].data[h.data.len-1] = v[i].data[h.data.len-1] + 1
  Opt.some(v)

type
  ExtraVersionedHash* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: ExtraVersionedHash,
                          baseVersionedHashes: openArray[common.Hash256]): Opt[seq[common.Hash256]] =
  var v = newSeq[common.Hash256](baseVersionedHashes.len + 1)
  for i, h in baseVersionedHashes:
    v[i] = h

  var extraHash = common.Hash256.randomBytes()
  extraHash.data[0] = VERSIONED_HASH_VERSION_KZG
  v[^1] = extraHash
  Opt.some(v)

type
  PayloadCustomizer* = ref object of EngineAPIVersionResolver

method customizePayload*(cust: PayloadCustomizer, data: ExecutableData): ExecutableData {.base, gcsafe.} =
  doAssert(false, "customizePayload unimplemented")

method getTimestamp(cust: PayloadCustomizer, basePayload: ExecutionPayload): uint64 {.base, gcsafe.} =
  doAssert(false, "getTimestamp unimplemented")

type
  NewPayloadCustomizer* = ref object of PayloadCustomizer
    expectedError*      : int
    expectInvalidStatus*: bool

method getExpectedError*(cust: NewPayloadCustomizer): int {.base, gcsafe.} =
  cust.expectedError

method getExpectInvalidStatus*(cust: NewPayloadCustomizer): bool {.base, gcsafe.}=
  cust.expectInvalidStatus

type
  CustomPayloadData* = object
    parentHash*               : Opt[common.Hash256]
    feeRecipient*             : Opt[common.EthAddress]
    stateRoot*                : Opt[common.Hash256]
    receiptsRoot*             : Opt[common.Hash256]
    logsBloom*                : Opt[BloomFilter]
    prevRandao*               : Opt[common.Bytes32]
    number*                   : Opt[uint64]
    gasLimit*                 : Opt[GasInt]
    gasUsed*                  : Opt[GasInt]
    timestamp*                : Opt[uint64]
    extraData*                : Opt[common.Blob]
    baseFeePerGas*            : Opt[UInt256]
    blockHash*                : Opt[common.Hash256]
    transactions*             : Opt[seq[Transaction]]
    withdrawals*              : Opt[seq[Withdrawal]]
    removeWithdrawals*        : bool
    blobGasUsed*              : Opt[uint64]
    removeBlobGasUsed*        : bool
    excessBlobGas*            : Opt[uint64]
    removeExcessBlobGas*      : bool
    parentBeaconRoot*         : Opt[common.Hash256]
    removeParentBeaconRoot*   : bool
    versionedHashesCustomizer*: VersionedHashesCustomizer

func getTimestamp*(cust: CustomPayloadData, basePayload: ExecutionPayload): uint64 =
  if cust.timestamp.isSome:
    return cust.timestamp.get
  return basePayload.timestamp.uint64

# Construct a customized payload by taking an existing payload as base and mixing it CustomPayloadData
# blockHash is calculated automatically.
proc customizePayload*(cust: CustomPayloadData, data: ExecutableData): ExecutableData {.gcsafe.} =
  var customHeader = blockHeader(data.basePayload, beaconRoot = data.beaconRoot)
  if cust.transactions.isSome:
    customHeader.transactionsRoot = calcTxRoot(cust.transactions.get)

  # Overwrite custom information
  if cust.parentHash.isSome:
    customHeader.parentHash = cust.parentHash.get

  if cust.feeRecipient.isSome:
    customHeader.coinbase = cust.feeRecipient.get

  if cust.stateRoot.isSome:
    customHeader.stateRoot = cust.stateRoot.get

  if cust.receiptsRoot.isSome:
    customHeader.receiptsRoot = cust.receiptsRoot.get

  if cust.logsBloom.isSome:
    customHeader.logsBloom = cust.logsBloom.get

  if cust.prevRandao.isSome:
    customHeader.mixHash = cust.prevRandao.get

  if cust.number.isSome:
    customHeader.number = cust.number.get

  if cust.gasLimit.isSome:
    customHeader.gasLimit = cust.gasLimit.get

  if cust.gasUsed.isSome:
    customHeader.gasUsed = cust.gasUsed.get

  if cust.timestamp.isSome:
    customHeader.timestamp = cust.timestamp.get.EthTime

  if cust.extraData.isSome:
    customHeader.extraData = cust.extraData.get

  if cust.baseFeePerGas.isSome:
    customHeader.baseFeePerGas = cust.baseFeePerGas

  if cust.removeWithdrawals:
    customHeader.withdrawalsRoot = Opt.none(common.Hash256)
  elif cust.withdrawals.isSome:
    let h = calcWithdrawalsRoot(cust.withdrawals.get)
    customHeader.withdrawalsRoot = Opt.some(h)

  if cust.removeBlobGasUsed:
    customHeader.blobGasUsed = Opt.none(uint64)
  elif cust.blobGasUsed.isSome:
    customHeader.blobGasUsed = cust.blobGasUsed

  if cust.removeExcessBlobGas:
    customHeader.excessBlobGas = Opt.none(uint64)
  elif cust.excessBlobGas.isSome:
    customHeader.excessBlobGas = cust.excessBlobGas

  if cust.removeParentBeaconRoot:
    customHeader.parentBeaconBlockRoot = Opt.none(common.Hash256)
  elif cust.parentBeaconRoot.isSome:
    customHeader.parentBeaconBlockRoot = cust.parentBeaconRoot

  var blk = EthBlock(
    header: customHeader,
    transactions:
      if cust.transactions.isSome:
        cust.transactions.get
      else:
        ethTxs data.basePayload.transactions
  )

  if cust.removeWithdrawals:
    blk.withdrawals = Opt.none(seq[Withdrawal])
  elif cust.withdrawals.isSome:
    blk.withdrawals = cust.withdrawals
  elif data.basePayload.withdrawals.isSome:
    blk.withdrawals = ethWithdrawals data.basePayload.withdrawals

  result = ExecutableData(
    basePayload    : executionPayload(blk),
    beaconRoot     : blk.header.parentBeaconBlockRoot,
    attr           : data.attr,
    versionedHashes: data.versionedHashes,
  )

  if cust.versionedHashesCustomizer.isNil.not:
    doAssert(data.versionedHashes.isSome)
    result.versionedHashes = cust.versionedHashesCustomizer.getVersionedHashes(data.versionedHashes.get)

# Base new payload directive call cust.
# Used as base to other customizers.
type
  BaseNewPayloadVersionCustomizer* = ref object of NewPayloadCustomizer
    payloadCustomizer*  : CustomPayloadData

method customizePayload(cust: BaseNewPayloadVersionCustomizer, data: ExecutableData): ExecutableData =
  cust.payloadCustomizer.customizePayload(data)

# Customizer that upgrades the version of the payload to the next version.
type
  UpgradeNewPayloadVersion* = ref object of BaseNewPayloadVersionCustomizer

method newPayloadVersion(cust: UpgradeNewPayloadVersion, timestamp: uint64): Version =
  let version = procCall newPayloadVersion(EngineAPIVersionResolver(cust), timestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

# Customizer that downgrades the version of the payload to the previous version.
type
  DowngradeNewPayloadVersion* = ref object of BaseNewPayloadVersionCustomizer

method newPayloadVersion(cust: DowngradeNewPayloadVersion, timestamp: uint64): Version =
  let version = procCall newPayloadVersion(EngineAPIVersionResolver(cust), timestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

proc customizePayloadTransactions*(data: ExecutableData, customTransactions: openArray[Transaction]): ExecutableData =
  let cpd = CustomPayloadData(
    transactions: Opt.some(@customTransactions),
  )
  customizePayload(cpd, data)

proc `$`*(cust: CustomPayloadData): string =
  var fieldList = newSeq[string]()

  if cust.parentHash.isSome:
    fieldList.add "parentHash=" & cust.parentHash.get.short

  if cust.feeRecipient.isSome:
    fieldList.add "Coinbase=" & $cust.feeRecipient.get

  if cust.stateRoot.isSome:
    fieldList.add "stateRoot=" & cust.stateRoot.get.short

  if cust.receiptsRoot.isSome:
    fieldList.add "receiptsRoot=" & cust.receiptsRoot.get.short

  if cust.logsBloom.isSome:
    fieldList.add "logsBloom=" & cust.logsBloom.get.toHex

  if cust.prevRandao.isSome:
    fieldList.add "prevRandao=" & cust.prevRandao.get.short

  if cust.number.isSome:
    fieldList.add "Number=" & $cust.number.get

  if cust.gasLimit.isSome:
    fieldList.add "gasLimit=" & $cust.gasLimit.get

  if cust.gasUsed.isSome:
    fieldList.add "gasUsed=" & $cust.gasUsed.get

  if cust.timestamp.isSome:
    fieldList.add "timestamp=" & $cust.timestamp.get

  if cust.extraData.isSome:
    fieldList.add "extraData=" & cust.extraData.get.toHex

  if cust.baseFeePerGas.isSome:
    fieldList.add "baseFeePerGas=" & $cust.baseFeePerGas.get

  if cust.transactions.isSome:
    fieldList.add "transactions=" & $cust.transactions.get.len

  if cust.withdrawals.isSome:
    fieldList.add "withdrawals=" & $cust.withdrawals.get.len

  fieldList.join(", ")

type
  InvalidPayloadBlockField* = enum
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
    InvalidTransactionGasTipPrice
    InvalidTransactionChainID
    InvalidParentBeaconBlockRoot
    InvalidExcessBlobGas
    InvalidBlobGasUsed
    InvalidBlobCountGasUsed
    InvalidVersionedHashesVersion
    InvalidVersionedHashes
    IncompleteVersionedHashes
    ExtraVersionedHashes
    InvalidWithdrawals

func scramble(data: Web3Hash): Opt[Hash32] =
  var h = ethHash data
  h.data[^1] = byte(255 - h.data[^1])
  Opt.some(h)

func scramble(data: Bytes32): Opt[Hash32] =
  var h = Hash32 data
  h.data[0] = byte(255 - h.data[0])
  Opt.some(h)

# This function generates an invalid payload by taking a base payload and modifying the specified field such that it ends up being invalid.
# One small consideration is that the payload needs to contain transactions and specially transactions using the PREVRANDAO opcode for all the fields to be compatible with this function.
proc generateInvalidPayload*(sender: TxSender, data: ExecutableData, payloadField: InvalidPayloadBlockField): ExecutableData =
  var customPayloadMod: CustomPayloadData
  let basePayload = data.basePayload

  case payloadField
  of InvalidParentHash:
    customPayloadMod = CustomPayloadData(
      parentHash: scramble(basePayload.parentHash),
    )
  of InvalidStateRoot:
    customPayloadMod = CustomPayloadData(
      stateRoot: scramble(basePayload.stateRoot),
    )
  of InvalidReceiptsRoot:
    customPayloadMod = CustomPayloadData(
      receiptsRoot: scramble(basePayload.receiptsRoot),
    )
  of InvalidNumber:
    let modNumber = basePayload.blockNumber.uint64 - 1
    customPayloadMod = CustomPayloadData(
      number: Opt.some(modNumber),
    )
  of InvalidGasLimit:
    let modGasLimit = basePayload.gasLimit.GasInt * 2
    customPayloadMod = CustomPayloadData(
      gasLimit: Opt.some(modGasLimit),
    )
  of InvalidGasUsed:
    let modGasUsed = basePayload.gasUsed.GasInt - 1
    customPayloadMod = CustomPayloadData(
      gasUsed: Opt.some(modGasUsed),
    )
  of InvalidTimestamp:
    let modTimestamp = basePayload.timestamp.uint64 - 1
    customPayloadMod = CustomPayloadData(
      timestamp: Opt.some(modTimestamp),
    )
  of InvalidPrevRandao:
    # This option potentially requires a transaction that uses the PREVRANDAO opcode.
    # Otherwise the payload will still be valid.
    let randomHash = common.Hash32.randomBytes()
    customPayloadMod = CustomPayloadData(
      prevRandao: Opt.some(Bytes32 randomHash.data),
    )
  of InvalidParentBeaconBlockRoot:
    doAssert(data.beaconRoot.isSome,
      "no parent beacon block root available for modification")
    customPayloadMod = CustomPayloadData(
      parentBeaconRoot: scramble(data.beaconRoot.get),
    )
  of InvalidBlobGasUsed:
    doAssert(basePayload.blobGasUsed.isSome, "no blob gas used available for modification")
    let modBlobGasUsed = basePayload.blobGasUsed.get.uint64 + 1
    customPayloadMod = CustomPayloadData(
      blobGasUsed: Opt.some(modBlobGasUsed),
    )
  of InvalidBlobCountGasUsed:
    doAssert(basePayload.blobGasUsed.isSome, "no blob gas used available for modification")
    let modBlobGasUsed = basePayload.blobGasUsed.get.uint64 + GAS_PER_BLOB
    customPayloadMod = CustomPayloadData(
      blobGasUsed: Opt.some(modBlobGasUsed),
    )
  of InvalidExcessBlobGas:
    doAssert(basePayload.excessBlobGas.isSome, "no excess blob gas available for modification")
    let modExcessBlobGas = basePayload.excessBlobGas.get.uint64 + 1
    customPayloadMod = CustomPayloadData(
      excessBlobGas: Opt.some(modExcessBlobGas),
    )
  of InvalidVersionedHashesVersion:
    doAssert(data.versionedHashes.isSome, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: IncreaseVersionVersionedHashes(),
    )
  of InvalidVersionedHashes:
    doAssert(data.versionedHashes.isSome, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: CorruptVersionedHashes(),
    )
  of IncompleteVersionedHashes:
    doAssert(data.versionedHashes.isSome, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: RemoveVersionedHash(),
    )
  of ExtraVersionedHashes:
    doAssert(data.versionedHashes.isSome, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: ExtraVersionedHash(),
    )
  of InvalidWithdrawals:
    # These options are not supported yet.
    # TODO: Implement
    doAssert(false, "invalid payload field not supported yet: " & $payloadField)
  of RemoveTransaction:
    let emptyTxs = newSeq[Transaction]()
    customPayloadMod = CustomPayloadData(
      transactions: Opt.some(emptyTxs),
    )
  of InvalidTransactionSignature,
    InvalidTransactionNonce,
    InvalidTransactionGas,
    InvalidTransactionGasPrice,
    InvalidTransactionGasTipPrice,
    InvalidTransactionValue,
    InvalidTransactionChainID:

    doAssert(basePayload.transactions.len > 0, "no transactions available for modification")
    let baseTx = rlp.decode(distinctBase basePayload.transactions[0], Transaction)
    var custTx: CustomTransactionData

    case payloadField
    of InvalidTransactionSignature:
      var sig = CustSig(R: baseTx.R - 1.u256)
      custTx.signature = Opt.some(sig)
    of InvalidTransactionNonce:
      custTx.nonce = Opt.some(baseTx.nonce - 1)
    of InvalidTransactionGas:
      custTx.gas = Opt.some(0.GasInt)
    of InvalidTransactionGasPrice:
      custTx.gasPriceOrGasFeeCap = Opt.some(0.GasInt)
    of InvalidTransactionGasTipPrice:
      custTx.gasTipCap = Opt.some(gasTipPrice.GasInt * 2.GasInt)
    of InvalidTransactionValue:
      # Vault account initially has 0x123450000000000000000, so this value should overflow
      custTx.value = Opt.some(UInt256.fromHex("0x123450000000000000001"))
    of InvalidTransactionChainID:
      custTx.chainId = Opt.some(ChainId(baseTx.chainId.uint64 + 1))
    else: discard

    let acc = sender.getNextAccount()
    let modifiedTx = sender.customizeTransaction(acc, baseTx, custTx)
    customPayloadMod = CustomPayloadData(
      transactions: Opt.some(@[modifiedTx]),
    )

  customPayloadMod.customizePayload(data)

# Generates an alternative withdrawals list that contains the same
# amounts and accounts, but the order in the list is different, so
# stateRoot of the resulting payload should be the same.

when false:
  proc randomizeWithdrawalsOrder(src: openArray[Withdrawal]): seq[Withdrawal] =
    result = @src
    result.shuffle
