# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/stateless-ethereum-specs/blob/master/state-network.md#content

{.push raises: [Defect].}

import
  nimcrypto/[sha2, hash], eth/ssz/ssz_serialization

type
  ByteList* = List[byte, 2048]

  ContentType* = enum
    Account = 0x01
    ContractStorage = 0x02
    ContractBytecode = 0x03

  NetworkId* = uint16

  NodeHash* = List[byte, 32] # MDigest[32 * 8] - sha256

  CodeHash* = List[byte, 32] # MDigest[32 * 8] - keccak256

  Address* = List[byte, 20]

  ContentKey* = object
    # TODO: How shall we deal with the different ContentKey structures?
    networkId: NetworkId
    contentType: ContentType
    address: Address
    triePath: ByteList
    nodeHash: NodeHash

  ContentId* = MDigest[32 * 8]

template toSszType*(x: auto): auto =
  mixin toSszType

  when x is ContentType: uint8(x)
  else: x

func toContentId*(contentKey: ContentKey): ContentId =
  sha2.sha_256.digest(SSZ.encode(contentKey))
