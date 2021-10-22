# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values

{.push raises: [Defect].}

import
  std/options,
  nimcrypto/[sha2, hash], stew/objects, stint,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types

type
  ContentType* = enum
    BlockHeader = 0x01
    BlockBody = 0x02
    Receipts = 0x03

  BlockHash* = MDigest[32 * 8] # Bytes32

  ContentKey* = object
    chainId*: uint16
    contentType*: ContentType
    blockHash*: BlockHash

  ContentId* = Uint256

template toSszType*(x: ContentType): uint8 =
  uint8(x)

template toSszType*(x: auto): auto =
  x

func fromSszBytes*(T: type ContentType, data: openArray[byte]):
    T {.raises: [MalformedSszError, Defect].} =
  if data.len != sizeof(uint8):
    raiseIncorrectSize T

  var contentType: T
  if not checkedEnumAssign(contentType, data[0]):
    raiseIncorrectSize T

  contentType

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
