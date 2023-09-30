# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  stint,
  web3/ethtypes,
  web3/engine_api_types

export
  engine_api_types

type
  ExecutionPayload* = object
    parentHash*: Hash256
    feeRecipient*: Address
    stateRoot*: Hash256
    receiptsRoot*: Hash256
    logsBloom*: FixedBytes[256]
    prevRandao*: FixedBytes[32]
    blockNumber*: Quantity
    gasLimit*: Quantity
    gasUsed*: Quantity
    timestamp*: Quantity
    extraData*: DynamicBytes[0, 32]
    baseFeePerGas*: UInt256
    blockHash*: Hash256
    transactions*: seq[TypedTransaction]
    withdrawals*: Option[seq[WithdrawalV1]]
    blobGasUsed*: Option[Quantity]
    excessBlobGas*: Option[Quantity]

  PayloadAttributes* = object
    timestamp*: Quantity
    prevRandao*: FixedBytes[32]
    suggestedFeeRecipient*: Address
    withdrawals*: Option[seq[WithdrawalV1]]
    parentBeaconBlockRoot*: Option[FixedBytes[32]]

  SomePayloadAttributes* =
    PayloadAttributesV1 |
    PayloadAttributesV2 |
    PayloadAttributesV3

  SomeOptionalPayloadAttributes* =
    Option[PayloadAttributesV1] |
    Option[PayloadAttributesV2] |
    Option[PayloadAttributesV3]

  GetPayloadResponse* = object
    executionPayload*: ExecutionPayload
    blockValue*: Option[UInt256]
    blobsBundle*: Option[BlobsBundleV1]

  Version* {.pure.} = enum
    V1
    V2
    V3

func version*(payload: ExecutionPayload): Version =
  if payload.blobGasUsed.isSome and payload.excessBlobGas.isSome:
    Version.V3
  elif payload.withdrawals.isSome:
    Version.V2
  else:
    Version.V1

func version*(attr: PayloadAttributes): Version =
  if attr.parentBeaconBlockRoot.isSome:
    Version.V3
  elif attr.withdrawals.isSome:
    Version.V2
  else:
    Version.V1

func version*(res: GetPayloadResponse): Version =
  if res.blobsBundle.isSome:
    Version.V3
  elif res.blockValue.isSome:
    Version.V2
  else:
    Version.V1

func V1V2*(attr: PayloadAttributes): PayloadAttributesV1OrV2 =
  PayloadAttributesV1OrV2(
    timestamp: attr.timestamp,
    prevRandao: attr.prevRandao,
    suggestedFeeRecipient: attr.suggestedFeeRecipient,
    withdrawals: attr.withdrawals
  )

func V1*(attr: PayloadAttributes): PayloadAttributesV1 =
  PayloadAttributesV1(
    timestamp: attr.timestamp,
    prevRandao: attr.prevRandao,
    suggestedFeeRecipient: attr.suggestedFeeRecipient
  )

func V2*(attr: PayloadAttributes): PayloadAttributesV2 =
  PayloadAttributesV2(
    timestamp: attr.timestamp,
    prevRandao: attr.prevRandao,
    suggestedFeeRecipient: attr.suggestedFeeRecipient,
    withdrawals: attr.withdrawals.get
  )

func V3*(attr: PayloadAttributes): PayloadAttributesV3 =
  PayloadAttributesV3(
    timestamp: attr.timestamp,
    prevRandao: attr.prevRandao,
    suggestedFeeRecipient: attr.suggestedFeeRecipient,
    withdrawals: attr.withdrawals.get,
    parentBeaconBlockRoot: attr.parentBeaconBlockRoot.get
  )

func V1*(attr: Option[PayloadAttributes]): Option[PayloadAttributesV1] =
  if attr.isNone:
    return none(PayloadAttributesV1)
  some(attr.get.V1)

when false:
  func V2*(attr: Option[PayloadAttributes]): Option[PayloadAttributesV2] =
    if attr.isNone:
      return none(PayloadAttributesV2)
    some(attr.get.V2)

  func V3*(attr: Option[PayloadAttributes]): Option[PayloadAttributesV3] =
    if attr.isNone:
      return none(PayloadAttributesV3)
    some(attr.get.V3)

func payloadAttributes*(attr: PayloadAttributesV1): PayloadAttributes =
  PayloadAttributes(
    timestamp: attr.timestamp,
    prevRandao: attr.prevRandao,
    suggestedFeeRecipient: attr.suggestedFeeRecipient
  )

func payloadAttributes*(x: Option[PayloadAttributesV1]): Option[PayloadAttributes] =
  if x.isNone: none(PayloadAttributes)
  else: some(payloadAttributes x.get)

func V1V2*(p: ExecutionPayload): ExecutionPayloadV1OrV2 =
  ExecutionPayloadV1OrV2(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: p.withdrawals
  )

func V1*(p: ExecutionPayload): ExecutionPayloadV1 =
  ExecutionPayloadV1(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions
  )

func V2*(p: ExecutionPayload): ExecutionPayloadV2 =
  ExecutionPayloadV2(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: p.withdrawals.get
  )

func V3*(p: ExecutionPayload): ExecutionPayloadV3 =
  ExecutionPayloadV3(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: p.withdrawals.get,
    blobGasUsed: p.blobGasUsed.get,
    excessBlobGas: p.excessBlobGas.get
  )

func V1*(p: ExecutionPayloadV1OrV2): ExecutionPayloadV1 =
  ExecutionPayloadV1(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions
  )

func V2*(p: ExecutionPayloadV1OrV2): ExecutionPayloadV2 =
  ExecutionPayloadV2(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: p.withdrawals.get
  )

func executionPayload*(p: ExecutionPayloadV1): ExecutionPayload =
  ExecutionPayload(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions
  )

func executionPayload*(p: ExecutionPayloadV2): ExecutionPayload =
  ExecutionPayload(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: some(p.withdrawals)
  )

func executionPayload*(p: ExecutionPayloadV3): ExecutionPayload =
  ExecutionPayload(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: some(p.withdrawals),
    blobGasUsed: some(p.blobGasUsed),
    excessBlobGas: some(p.excessBlobGas)
  )

func executionPayload*(p: ExecutionPayloadV1OrV2): ExecutionPayload =
  ExecutionPayload(
    parentHash: p.parentHash,
    feeRecipient: p.feeRecipient,
    stateRoot: p.stateRoot,
    receiptsRoot: p.receiptsRoot,
    logsBloom: p.logsBloom,
    prevRandao: p.prevRandao,
    blockNumber: p.blockNumber,
    gasLimit: p.gasLimit,
    gasUsed: p.gasUsed,
    timestamp: p.timestamp,
    extraData: p.extraData,
    baseFeePerGas: p.baseFeePerGas,
    blockHash: p.blockHash,
    transactions: p.transactions,
    withdrawals: p.withdrawals
  )

func V1*(res: GetPayloadResponse): ExecutionPayloadV1 =
  res.executionPayload.V1

func V2*(res: GetPayloadResponse): GetPayloadV2Response =
  GetPayloadV2Response(
    executionPayload: res.executionPayload.V1V2,
    blockValue: res.blockValue.get
  )

func V3*(res: GetPayloadResponse): GetPayloadV3Response =
  GetPayloadV3Response(
    executionPayload: res.executionPayload.V3,
    blockValue: res.blockValue.get,
    blobsBundle: res.blobsBundle.get
  )
