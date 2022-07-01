# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

{.push raises: [Defect].}

import
  std/[options, math],
  nimcrypto/[sha2, hash], stew/byteutils, stint,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, hash

## Types and calls for history network content keys

type
  ContentType* = enum
    blockHeader = 0x00
    blockBody = 0x01
    receipts = 0x02
    epochAccumulator = 0x03
    masterAccumulator = 0x04

  BlockKey* = object
    chainId*: uint16
    blockHash*: BlockHash

  EpochAccumulatorKey* = object
    epochHash*: Digest

  MasterAccumulatorKeyType* = enum
    latest = 0x00 # An SSZ Union None
    masterHash = 0x01

  MasterAccumulatorKey* = object
    case accumulaterKeyType*: MasterAccumulatorKeyType
    of latest:
      discard
    of masterHash:
      masterHashKey*: Digest

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
    of masterAccumulator:
      masterAccumulatorKey*: MasterAccumulatorKey

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Option[ContentKey] =
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha_256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func `$`*(x: BlockHash): string =
  "0x" & x.data.toHex()

func `$`*(x: BlockKey): string =
  "blockHash: " & $x.blockHash & ", chainId: " & $x.chainId

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
  of masterAccumulator:
    let key = x.masterAccumulatorKey
    case key.accumulaterKeyType:
    of latest:
      res.add($key.accumulaterKeyType)
    of masterHash:
      res.add($key.accumulaterKeyType & ": " & $key.masterHashKey)

  res.add(")")

  res

## Types for history network content

const
  MAX_TRANSACTION_LENGTH* = 2^24  # ~= 16 million
  MAX_TRANSACTION_COUNT* = 2^14  # ~= 16k
  MAX_RECEIPT_LENGTH* = 2^27  # ~= 134 million
  MAX_HEADER_LENGTH = 2^13  # = 8192
  MAX_ENCODED_UNCLES_LENGTH* = MAX_HEADER_LENGTH * 2^4  # = 2**17 ~= 131k

type
  ## Types for content
  # TODO: Using `init` on these lists appears to fail because of the constants
  # that are used? Strange.
  TransactionByteList* = List[byte, MAX_TRANSACTION_LENGTH] # RLP data
  Transactions* = List[TransactionByteList, MAX_TRANSACTION_COUNT]
  Uncles* = List[byte, MAX_ENCODED_UNCLES_LENGTH] # RLP data

  BlockBodySSZ* = object
    transactions*: Transactions
    uncles*: Uncles

  ReceiptByteList* = List[byte, MAX_RECEIPT_LENGTH] # RLP data
  ReceiptsSSZ* = List[ReceiptByteList, MAX_TRANSACTION_COUNT]
