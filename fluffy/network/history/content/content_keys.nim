# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  nimcrypto/[sha2, hash],
  stew/byteutils,
  results,
  stint,
  ssz_serialization,
  ../../../common/common_types

export ssz_serialization, common_types, hash, results

## History network content keys:
## https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

const
  # Maximum content key size:
  # - 32 bytes for SSZ serialized `BlockKey`
  # - 1 byte for `ContentType`
  maxContentKeySize* = 33

type
  ContentType* = enum
    blockHeader = 0x00
    blockBody = 0x01
    receipts = 0x02
    blockNumber = 0x03

  BlockKey* = object
    blockHash*: BlockHash

  BlockNumberKey* = object
    blockNumber*: uint64

  ContentKey* = object
    case contentType*: ContentType
    of blockHeader:
      blockHeaderKey*: BlockKey
    of blockBody:
      blockBodyKey*: BlockKey
    of receipts:
      receiptsKey*: BlockKey
    of blockNumber:
      blockNumberKey*: BlockNumberKey

func blockHeaderContentKey*(id: BlockHash | uint64): ContentKey =
  when id is BlockHash:
    ContentKey(contentType: blockHeader, blockHeaderKey: BlockKey(blockHash: id))
  else:
    ContentKey(
      contentType: blockNumber, blockNumberKey: BlockNumberKey(blockNumber: id)
    )

func blockBodyContentKey*(hash: BlockHash): ContentKey =
  ContentKey(contentType: blockBody, blockBodyKey: BlockKey(blockHash: hash))

func receiptsContentKey*(hash: BlockHash): ContentKey =
  ContentKey(contentType: receipts, receiptsKey: BlockKey(blockHash: hash))

func encode*(contentKey: ContentKey): ContentKeyByteList =
  ContentKeyByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ContentKeyByteList): Opt[ContentKey] =
  try:
    Opt.some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SerializationError:
    return Opt.none(ContentKey)

func toContentId*(contentKey: ContentKeyByteList): ContentId =
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

  case x.contentType
  of blockHeader:
    res.add($x.blockHeaderKey)
  of blockBody:
    res.add($x.blockBodyKey)
  of receipts:
    res.add($x.receiptsKey)
  of blockNumber:
    res.add($x.blockNumberKey)

  res.add(")")

  res
