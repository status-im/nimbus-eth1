# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  stew/arrayops,
  eth/rlp,
  eth/common/[hashes, addresses, base_rlp, accounts_rlp],
  ./state_content

export results, hashes, accounts, addresses, rlp

template fromBytes*(T: type Hash32, hash: openArray[byte]): T =
  doAssert(hash.len() == 32)
  Hash32(array[32, byte].initCopyFrom(hash))

func decodePrefix*(nodePrefixRlp: Rlp): (byte, bool, Nibbles) {.raises: RlpError.} =
  doAssert(not nodePrefixRlp.isEmpty())

  let
    rlpBytes = nodePrefixRlp.toBytes()
    firstNibble = (rlpBytes[0] and 0xF0) shr 4
    isLeaf = firstNibble == 2 or firstNibble == 3
    isEven = firstNibble == 0 or firstNibble == 2
    startIdx = if isEven: 1 else: 0
    nibbles = Nibbles.init(rlpBytes[startIdx .. ^1], isEven)

  (firstNibble.byte, isLeaf, nibbles)

func rlpDecodeAccountTrieNode*(accountTrieNode: TrieNode): Result[Account, string] =
  try:
    let accNodeRlp = rlpFromBytes(accountTrieNode.asSeq())
    if accNodeRlp.isEmpty() or accNodeRlp.listLen() != 2:
      return err("invalid account trie node - malformed")

    let accNodePrefixRlp = accNodeRlp.listElem(0)
    if accNodePrefixRlp.isEmpty():
      return err("invalid account trie node - empty prefix")

    let (_, isLeaf, _) = decodePrefix(accNodePrefixRlp)
    if not isLeaf:
      return err("invalid account trie node - leaf prefix expected")

    decodeRlp(accNodeRlp.listElem(1).toBytes(), Account)
  except RlpError as e:
    err(e.msg)

func rlpDecodeContractTrieNode*(contractTrieNode: TrieNode): Result[UInt256, string] =
  try:
    let storageNodeRlp = rlpFromBytes(contractTrieNode.asSeq())
    if storageNodeRlp.isEmpty() or storageNodeRlp.listLen() != 2:
      return err("invalid contract trie node - malformed")

    let storageNodePrefixRlp = storageNodeRlp.listElem(0)
    if storageNodePrefixRlp.isEmpty():
      return err("invalid contract trie node - empty prefix")

    let (_, isLeaf, _) = decodePrefix(storageNodePrefixRlp)
    if not isLeaf:
      return err("invalid contract trie node - leaf prefix expected")

    decodeRlp(storageNodeRlp.listElem(1).toBytes(), UInt256)
  except RlpError as e:
    err(e.msg)

template toAccount*(accountProof: TrieProof): Result[Account, string] =
  doAssert(accountProof.len() > 0)
  rlpDecodeAccountTrieNode(accountProof[^1])

template toSlot*(storageProof: TrieProof): Result[UInt256, string] =
  doAssert(storageProof.len() > 0)
  rlpDecodeContractTrieNode(storageProof[^1])

func removeLeafKeyEndNibbles*(
    nibbles: Nibbles, leafNode: TrieNode
): Nibbles {.raises: RlpError.} =
  let nodeRlp = rlpFromBytes(leafNode.asSeq())
  doAssert(nodeRlp.listLen() == 2)
  let (_, isLeaf, prefix) = decodePrefix(nodeRlp.listElem(0))
  doAssert(isLeaf)

  let leafPrefix = prefix.unpackNibbles()
  var unpackedNibbles = nibbles.unpackNibbles()
  doAssert(unpackedNibbles[^leafPrefix.len() .. ^1] == leafPrefix)

  unpackedNibbles.dropN(leafPrefix.len()).packNibbles()

template toPath*(hash: Hash32): Nibbles =
  Nibbles.init(hash.data, isEven = true)

template toPath*(address: Address): Nibbles =
  keccak256(address.data).toPath()

template toPath*(slotKey: UInt256): Nibbles =
  keccak256(toBytesBE(slotKey)).toPath()
