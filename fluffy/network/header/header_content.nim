# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md

{.push raises: [].}

import
  std/options,
  nimcrypto/[sha2, hash], stint,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, options, hash

type
  # Header Gossip Content Keys
  # https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md#content-keys
  # But with Accumulator removed as per
  # https://github.com/ethereum/portal-network-specs/issues/153

  ContentType* = enum
    newBlockHeader = 0x00
    # TODO: remove or fix this temporary 
    # dummySelector per latest spec.
    # This is temporary workaround
    # to fool SSZ.isUnion    
    dummySelector  = 0x01

  NewBlockHeaderKey* = object
    blockHash*: BlockHash
    blockNumber*: UInt256

  ContentKey* = object
    case contentType*: ContentType
    of newBlockHeader:
      newBlockHeaderKey*: NewBlockHeaderKey
    of dummySelector:
      dummyField: uint64

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Option[ContentKey] =
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))
