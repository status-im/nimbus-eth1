# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import
  nimcrypto/[hash, sha2, keccak], stew/[objects, results, endians2], stint,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, hash, results

type
  NodeHash*    = MDigest[32 * 8] # keccak256
  CodeHash*    = MDigest[32 * 8] # keccak256
  StorageHash* = MDigest[32 * 8] # keccak256
  StateRoot*   = MDigest[32 * 8] # keccak256
  Address*     = array[20, byte]

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
    contractStorageTrieNode = 0x21
    accountTrieProof = 0x22
    contractStorageTrieProof = 0x23
    contractBytecode = 0x24

  AccountTrieNodeKey* = object
    path*: ByteList
    nodeHash*: NodeHash
    stateRoot*: Bytes32

  ContractStorageTrieNodeKey* = object
    address*: Address
    path*: ByteList
    nodeHash*: NodeHash
    stateRoot*: Bytes32

  AccountTrieProofKey* = object
    address*: Address
    stateRoot*: Bytes32

  ContractStorageTrieProofKey* = object
    address*: Address
    slot*: UInt256
    stateRoot*: Bytes32

  ContractBytecodeKey* = object
    address*: Address
    codeHash*: CodeHash

  WitnessNode* = ByteList
  AccountTrieProof* = List[WitnessNode, 32]

  AccountState* = object
    nonce*: uint64
    balance*: UInt256
    storageHash*: StorageHash # is it NodeHash?
    codeHash*: CodeHash
    stateRoot*: StateRoot
    proof*: AccountTrieProof

  ContentKey* = object
    case contentType*: ContentType
    of unused:
      discard
    of accountTrieNode:
      accountTrieNodeKey*: AccountTrieNodeKey
    of contractStorageTrieNode:
      contractStorageTrieNodeKey*: ContractStorageTrieNodeKey
    of accountTrieProof:
      accountTrieProofKey*: AccountTrieProofKey
    of contractStorageTrieProof:
      contractStorageTrieProofKey*: ContractStorageTrieProofKey
    of contractBytecode:
      contractBytecodeKey*: ContractBytecodeKey

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

template computeContentId*(digestCtxType: type, body: untyped): ContentId =
  var h {.inject.}: digestCtxType
  init(h)
  body
  let idHash = finish(h)
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  case contentKey.contentType:
  of unused:
    raiseAssert "Should not be used and fail at decoding"
  of accountTrieNode: # sha256(path | node_hash)
    let key = contentKey.accountTrieNodeKey
    computeContentId sha256:
      h.update(key.path.asSeq())
      h.update(key.nodeHash.data)
  of contractStorageTrieNode: # sha256(address | path | node_hash)
    let key = contentKey.contractStorageTrieNodeKey
    computeContentId sha256:
      h.update(key.address)
      h.update(key.path.asSeq())
      h.update(key.nodeHash.data)
  of accountTrieProof: # keccak(address)
    let key = contentKey.accountTrieProofKey
    computeContentId keccak256:
      h.update(key.address)
  of contractStorageTrieProof: # (keccak(address) + keccak(slot)) % 2**256
    # TODO: Why is keccak run on slot, when it can be used directly?
    # Also, value to LE or BE? Not mentioned in specification.
    let key = contentKey.contractStorageTrieProofKey
    let n1 =
      block: computeContentId keccak256:
        h.update(key.address)
    let n2 =
      block: computeContentId keccak256:
        h.update(toBytesBE(key.slot))

    n1 + n2 # uint256 will wrap arround, practically applying the modulo 256
  of contractBytecode: # sha256(address | code_hash)
    let key = contentKey.contractBytecodeKey
    computeContentId sha256:
      h.update(key.address)
      h.update(key.codeHash.data)

proc toContentId*(contentKey: ByteList): results.Opt[ContentId] =
  let key = decode(contentKey)
  if key.isSome():
    ok(key.get().toContentId())
  else:
    Opt.none(ContentId)
