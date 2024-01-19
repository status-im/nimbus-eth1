# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import
  nimcrypto/[hash, sha2, keccak], stew/results, stint,
  eth/common/eth_types,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, hash, results

type
  NodeHash* = KeccakHash
  CodeHash* = KeccakHash
  Address*  = EthAddress

  ContentType* = enum
    # Note: Need to add this unused value as a case object with an enum without
    # a 0 valueis not allowed: "low(contentType) must be 0 for discriminant".
    # For prefix values that are in the enum gap, the deserialization will fail
    # at runtime as is wanted.
    # In the future it might be possible that this will fail at compile time for
    # the SSZ Union type, but currently it is allowed in the implementation, and
    # the SSZ spec is not explicit about disallowing this.
    unused = 0x00
    accountTrieNode = 0x20
    contractTrieNode = 0x21
    contractCode = 0x22

  NibblePair* = byte
  Nibbles* = object
    isOddLength*: bool
    packedNibbles*: List[NibblePair, 32]

  WitnessNode* = List[byte, 1024]
  Witness* = List[WitnessNode, 1024]

  StateWitness* = object
    key*: Nibbles
    proof*: Witness

  StorageWitness* = object
    key*: Nibbles
    proof*: Witness
    stateWitness*: StateWitness

  AccountTrieNodeKey* = object
    path*: Nibbles
    nodeHash*: NodeHash

  ContractTrieNodeKey* = object
    address*: Address
    path*: Nibbles
    nodeHash*: NodeHash

  ContractCodeKey* = object
    address*: Address
    codeHash*: CodeHash

  ContentKey* = object
    case contentType*: ContentType
    of unused:
      discard
    of accountTrieNode:
      accountTrieNodeKey*: AccountTrieNodeKey
    of contractTrieNode:
      contractTrieNodeKey*: ContractTrieNodeKey
    of contractCode:
      contractCodeKey*: ContractCodeKey

  AccountTrieNodeOffer* = object
    proof*: StateWitness
    blockHash*: BlockHash

  AccountTrieNodeRetrieval* = object
    node*: WitnessNode

  ContractTrieNodeOffer* = object
    proof*: StorageWitness
    blockHash*: BlockHash

  ContractTrieNodeRetrieval* = object
    node*: WitnessNode

  ContractCodeOffer* = object
    code*: ByteList
    accountProof*: StateWitness
    blockHash*: BlockHash

  ContractCodeRetrieval* = object
    code*: ByteList

func encode*(contentKey: ContentKey): ByteList =
  doAssert(contentKey.contentType != unused)
  ByteList.init(SSZ.encode(contentKey))

proc readSszBytes*(
    data: openArray[byte], val: var ContentKey
) {.raises: [SszError].} =
  mixin readSszValue
  if data.len() > 0 and data[0] == ord(unused):
    raise newException(MalformedSszError, "SSZ selector is unused value")

  readSszValue(data, val)

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
