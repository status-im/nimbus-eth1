# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

{.push raises: [].}

import
  std/math,
  nimcrypto/[sha2, hash], stew/[byteutils, results], stint,
  ssz_serialization,
  ../../common/common_types

from beacon_chain/spec/datatypes/capella import Withdrawal
from beacon_chain/spec/presets/mainnet import MAX_WITHDRAWALS_PER_PAYLOAD

export ssz_serialization, common_types, hash, results

## Types and calls for history network content keys

const
  # Maximum content key size:
  # - 32 bytes for SSZ serialized `BlockKey`
  # - 1 byte for `ContentType`
  # TODO: calculate it somehow from the object definition (macro?)
  maxContentKeySize* = 33

type
  ContentType* = enum
    blockHeader = 0x00
    blockBody = 0x01
    receipts = 0x02
    epochAccumulator = 0x03

  BlockKey* = object
    blockHash*: BlockHash

  EpochAccumulatorKey* = object
    epochHash*: Digest # TODO: Perhaps this should be called epochRoot in the spec instead

  ContentKey* = object
    case contentType*: ContentType
    of blockHeader:
      blockHeaderKey*: BlockKey
    of blockBody:
      blockBodyKey*: BlockKey
    of receipts:
      receiptsKey*: BlockKey
    of epochAccumulator:
      epochAccumulatorKey*: EpochAccumulatorKey

func init*(
    T: type ContentKey, contentType: ContentType,
    hash: BlockHash | Digest): T =
  case contentType
  of blockHeader:
    ContentKey(
      contentType: contentType, blockHeaderKey: BlockKey(blockHash: hash))
  of blockBody:
    ContentKey(
      contentType: contentType, blockBodyKey: BlockKey(blockHash: hash))
  of receipts:
    ContentKey(
      contentType: contentType, receiptsKey: BlockKey(blockHash: hash))
  of epochAccumulator:
    ContentKey(
      contentType: contentType,
      epochAccumulatorKey: EpochAccumulatorKey(epochHash: hash))

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Opt[ContentKey] =
  try:
    Opt.some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SerializationError:
    return Opt.none(ContentKey)

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func `$`*(x: BlockHash): string =
  "0x" & x.data.toHex()

func `$`*(x: BlockKey): string =
  "blockHash: " & $x.blockHash

func `$`*(x: ContentKey): string =
  var res = "(type: " & $x.contentType & ", "

  case x.contentType:
  of blockHeader:
    res.add($x.blockHeaderKey)
  of blockBody:
    res.add($x.blockBodyKey)
  of receipts:
    res.add($x.receiptsKey)
  of epochAccumulator:
    let key = x.epochAccumulatorKey
    res.add("epochHash: " & $key.epochHash)

  res.add(")")

  res

## Types for history network content

const
  MAX_TRANSACTION_LENGTH* = 2^24  # ~= 16 million
  MAX_TRANSACTION_COUNT* = 2^14  # ~= 16k
  MAX_RECEIPT_LENGTH* = 2^27  # ~= 134 million
  MAX_HEADER_LENGTH = 2^13  # = 8192
  MAX_ENCODED_UNCLES_LENGTH* = MAX_HEADER_LENGTH * 2^4  # = 2**17 ~= 131k
  MAX_WITHDRAWAL_LENGTH = 64
  MAX_WITHDRAWALS_COUNT = MAX_WITHDRAWALS_PER_PAYLOAD

type
  ## Types for content
  # TODO: Using `init` on these lists appears to fail because of the constants
  # that are used? Strange.
  TransactionByteList* = List[byte, MAX_TRANSACTION_LENGTH] # RLP data
  Transactions* = List[TransactionByteList, MAX_TRANSACTION_COUNT]
  Uncles* = List[byte, MAX_ENCODED_UNCLES_LENGTH] # RLP data

  WithdrawalByteList* = List[byte, MAX_WITHDRAWAL_LENGTH] # RLP data
  Withdrawals* = List[WithdrawalByteList, MAX_WITHDRAWALS_COUNT]

  # Pre-shanghai block body
  # Post-merge this block body is required to have an empty list for uncles
  PortalBlockBodyLegacy* = object
    transactions*: Transactions
    uncles*: Uncles

  # Post-shanghai block body, added withdrawals
  PortalBlockBodyShanghai* = object
    transactions*: Transactions
    uncles*: Uncles
    withdrawals*: Withdrawals

  ReceiptByteList* = List[byte, MAX_RECEIPT_LENGTH] # RLP data
  PortalReceipts* = List[ReceiptByteList, MAX_TRANSACTION_COUNT]

  AccumulatorProof* = array[15, Digest]

  BlockHeaderProofType* = enum
    none = 0x00 # An SSZ Union None
    accumulatorProof = 0x01

  BlockHeaderProof* = object
    case proofType*: BlockHeaderProofType
    of none:
      discard
    of accumulatorProof:
      accumulatorProof*: AccumulatorProof

  BlockHeaderWithProof* = object
    header*: ByteList # RLP data
    proof*: BlockHeaderProof

func init*(T: type BlockHeaderProof, proof: AccumulatorProof): T =
  BlockHeaderProof(proofType: accumulatorProof, accumulatorProof: proof)

func init*(T: type BlockHeaderProof): T =
  BlockHeaderProof(proofType: none)
