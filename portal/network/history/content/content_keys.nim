# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, stint, ssz_serialization, ../../../common/common_types

export ssz_serialization, common_types, results

type
  ContentType* = enum
    blockBody = 0x00
    receipts = 0x01

  BlockNumberKey* = object
    blockNumber*: uint64

  ContentKey* = object
    case contentType*: ContentType
    of blockBody:
      blockBodyKey*: BlockNumberKey
    of receipts:
      receiptsKey*: BlockNumberKey

func blockBodyContentKey*(blockNumber: uint64): ContentKey =
  ContentKey(
    contentType: blockBody, blockBodyKey: BlockNumberKey(blockNumber: blockNumber)
  )

func receiptsContentKey*(blockNumber: uint64): ContentKey =
  ContentKey(
    contentType: receipts, receiptsKey: BlockNumberKey(blockNumber: blockNumber)
  )

template blockNumber*(contentKey: ContentKey): uint64 =
  ## Returns the block number for the given content key
  case contentKey.contentType
  of blockBody: contentKey.blockBodyKey.blockNumber
  of receipts: contentKey.receiptsKey.blockNumber

proc readSszBytes*(data: openArray[byte], val: var ContentKey) {.raises: [SszError].} =
  mixin readSszValue

  readSszValue(data, val)

func encode*(contentKey: ContentKey): ContentKeyByteList =
  ContentKeyByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ContentKeyByteList): Opt[ContentKey] =
  try:
    Opt.some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SerializationError:
    return Opt.none(ContentKey)

func reverseBits(n: uint64, width: int): uint64 =
  ## Reverse the lowest `width` bits of `n`
  # TODO: can improve
  var res: uint64 = 0
  for i in 0 ..< width:
    if ((n shr i) and 1) != 0:
      res = res or (1'u64 shl (width - 1 - i))
  res

const
  CYCLE_BITS = 16
  OFFSET_BITS = 256 - CYCLE_BITS # 240
  REVERSED_OFFSET_BITS = 64 - CYCLE_BITS # 48

func toContentId*(blockNumber: uint64, contentType: ContentType): UInt256 =
  ## Returns the content id for a given block number
  let
    cycleBits = blockNumber mod (1'u64 shl CYCLE_BITS)
    offsetBits = blockNumber div (1'u64 shl CYCLE_BITS)

    reversedOffsetBits = reverseBits(offsetBits, REVERSED_OFFSET_BITS)

  (cycleBits.stuint(256) shl OFFSET_BITS) or
    (reversedOffsetBits.stuint(256) shl (OFFSET_BITS - REVERSED_OFFSET_BITS)) or
    ord(contentType).stuint(256)

func toContentId*(contentKey: ContentKey): ContentId =
  case contentKey.contentType
  of blockBody:
    toContentId(contentKey.blockBodyKey.blockNumber, contentKey.contentType)
  of receipts:
    toContentId(contentKey.receiptsKey.blockNumber, contentKey.contentType)

func toContentId*(bytes: ContentKeyByteList): Opt[ContentId] =
  let contentKey = ?bytes.decode()
  Opt.some(contentKey.toContentId())

func `$`*(x: BlockNumberKey): string =
  "block_number: " & $x.blockNumber

func `$`*(x: ContentKey): string =
  var res = "(type: " & $x.contentType & ", "

  case x.contentType
  of blockBody:
    res.add($x.blockBodyKey)
  of receipts:
    res.add($x.receiptsKey)

  res.add(")")

  res
