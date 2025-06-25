# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  nimcrypto/[sha2, hash],
  results,
  stint,
  ssz_serialization,
  ../../../common/common_types

export ssz_serialization, common_types, results#, hash

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
  ContentKey(contentType: blockBody, blockBodyKey: BlockNumberKey(blockNumber: blockNumber))

func receiptsContentKey*(blockNumber: uint64): ContentKey =
  ContentKey(contentType: receipts, receiptsKey: BlockNumberKey(blockNumber: blockNumber))

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

# TODO: change to correct content id derivation
func toContentId*(contentKey: ContentKeyByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

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
