# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import
  nimcrypto/[hash, sha2, keccak],
  results,
  stint,
  eth/common/hashes,
  ssz_serialization,
  ./nibbles

export ssz_serialization, common_types, hash, results

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
    accountTrieNode = 0x20
    contractTrieNode = 0x21
    contractCode = 0x22

  AccountTrieNodeKey* = object
    path*: Nibbles
    nodeHash*: Hash32

  ContractTrieNodeKey* = object
    addressHash*: Hash32
    path*: Nibbles
    nodeHash*: Hash32

  ContractCodeKey* = object
    addressHash*: Hash32
    codeHash*: Hash32

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

  ContentKeyType* = AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey

func init*(T: type AccountTrieNodeKey, path: Nibbles, nodeHash: Hash32): T =
  T(path: path, nodeHash: nodeHash)

func init*(
    T: type ContractTrieNodeKey, addressHash: Hash32, path: Nibbles, nodeHash: Hash32
): T =
  T(addressHash: addressHash, path: path, nodeHash: nodeHash)

func init*(
    T: type ContractCodeKey, addressHash: Hash32, codeHash: Hash32
): T {.inline.} =
  T(addressHash: addressHash, codeHash: codeHash)

template toContentKey*(key: AccountTrieNodeKey): ContentKey =
  ContentKey(contentType: accountTrieNode, accountTrieNodeKey: key)

template toContentKey*(key: ContractTrieNodeKey): ContentKey =
  ContentKey(contentType: contractTrieNode, contractTrieNodeKey: key)

template toContentKey*(key: ContractCodeKey): ContentKey =
  ContentKey(contentType: contractCode, contractCodeKey: key)

proc readSszBytes*(data: openArray[byte], val: var ContentKey) {.raises: [SszError].} =
  mixin readSszValue
  if data.len() > 0 and data[0] == ord(unused):
    raise newException(MalformedSszError, "SSZ selector is unused value")

  readSszValue(data, val)

func encode*(contentKey: ContentKey): ContentKeyByteList =
  doAssert(contentKey.contentType != unused)
  ContentKeyByteList.init(SSZ.encode(contentKey))

func decode*(
    T: type ContentKey, contentKey: ContentKeyByteList
): Result[T, string] {.inline.} =
  let key = ?decodeSsz(contentKey.asSeq(), T)
  if key.contentType == unused:
    return err("ContentKey contentType: unused")
  ok(key)

func toContentId*(contentKey: ContentKeyByteList): ContentId =
  let idHash = sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)
