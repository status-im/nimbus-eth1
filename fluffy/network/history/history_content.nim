# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

{.push raises: [Defect].}

import
  std/options,
  nimcrypto/[sha2, hash], stew/byteutils, stint,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types

type
  ContentType* = enum
    blockHeader = 0x00
    blockBody = 0x01
    receipts = 0x02

  BlockHash* = MDigest[32 * 8] # Bytes32

  ContentKeyType* = object
    chainId*: uint16
    blockHash*: BlockHash

  ContentKey* = object
    case contentType*: ContentType
    of blockHeader:
      blockHeaderKey*: ContentKeyType
    of blockBody:
      blockBodyKey*: ContentKeyType
    of receipts:
      receiptsKey*: ContentKeyType

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Option[ContentKey] =
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func toContentId*(contentKey: ByteList): ContentId =
  let idHash = sha2.sha_256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func `$`*(x: BlockHash): string =
  "0x" & x.data.toHex()

func `$`*(x: ContentKey): string =
  let key =
    case x.contentType:
    of blockHeader:
      x.blockHeaderKey
    of blockBody:
      x.blockBodyKey
    of receipts:
      x.receiptsKey

  "(contentType: " & $x.contentType &
    ", blockHash: " & $key.blockHash &
    ", chainId: " & $key.chainId & ")"
