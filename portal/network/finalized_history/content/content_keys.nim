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
    # Note: Need to add this unused value as a case object with an enum without
    # a 0 valueis not allowed: "low(contentType) must be 0 for discriminant".
    # For prefix values that are in the enum gap, the deserialization will fail
    # at runtime as is wanted.
    # In the future it might be possible that this will fail at compile time for
    # the SSZ Union type, but currently it is allowed in the implementation, and
    # the SSZ spec is not explicit about disallowing this.
    unused = 0x00
    blockBody = 0x09
    receipts = 0x0A

  BlockNumberKey* = object
    blockNumber*: uint64

  ContentKey* = object
    case contentType*: ContentType
    of unused:
      discard
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

proc readSszBytes*(data: openArray[byte], val: var ContentKey) {.raises: [SszError].} =
  mixin readSszValue
  if data.len() > 0 and data[0] == ord(unused):
    raise newException(MalformedSszError, "SSZ selector is unused value")

  readSszValue(data, val)

func encode*(contentKey: ContentKey): ContentKeyByteList =
  doAssert(contentKey.contentType != unused)
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

func toContentId*(blockNumber: uint64): UInt256 =
  ## Returns the content id for a given block number
  let
    cycleBits = blockNumber mod (1'u64 shl CYCLE_BITS)
    offsetBits = blockNumber div (1'u64 shl CYCLE_BITS)

    reversedOffsetBits = reverseBits(offsetBits, REVERSED_OFFSET_BITS)

  (cycleBits.stuint(256) shl OFFSET_BITS) or
    (reversedOffsetBits.stuint(256) shl (OFFSET_BITS - REVERSED_OFFSET_BITS))

func toContentId*(contentKey: ContentKey): ContentId =
  case contentKey.contentType
  of unused:
    raiseAssert "ContentKey may not have unused value as content type"
  of blockBody:
    toContentId(contentKey.blockBodyKey.blockNumber)
  of receipts:
    toContentId(contentKey.receiptsKey.blockNumber)

func toContentId*(bytes: ContentKeyByteList): Opt[ContentId] =
  let contentKey = ?bytes.decode()
  Opt.some(contentKey.toContentId())

func `$`*(x: BlockNumberKey): string =
  "block_number: " & $x.blockNumber

func `$`*(x: ContentKey): string =
  var res = "(type: " & $x.contentType & ", "

  case x.contentType
  of unused:
    raiseAssert "ContentKey may not have unused value as content type"
  of blockBody:
    res.add($x.blockBodyKey)
  of receipts:
    res.add($x.receiptsKey)

  res.add(")")

  res
