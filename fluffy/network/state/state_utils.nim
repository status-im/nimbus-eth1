# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, eth/common, ./state_content

export results, common

# For now we simply convert these Rlp errors to Defects
# because they generally shouldn't occur in practice.
# If and when they do occur, we can add more specific logic to handle them
template expectOk*(statements: untyped): auto =
  try:
    statements
  except RlpError as e:
    raiseAssert(e.msg)

func decodePrefix*(nodePrefixRlp: Rlp): (byte, bool, Nibbles) =
  doAssert(not nodePrefixRlp.isEmpty())

  let
    rlpBytes = nodePrefixRlp.toBytes().expectOk()
    firstNibble = (rlpBytes[0] and 0xF0) shr 4
    isLeaf = firstNibble == 2 or firstNibble == 3
    isEven = firstNibble == 0 or firstNibble == 2
    startIdx = if isEven: 1 else: 0
    nibbles = Nibbles.init(rlpBytes[startIdx .. ^1], isEven)

  (firstNibble.byte, isLeaf, nibbles)

func rlpDecodeAccountTrieNode*(accountTrieNode: TrieNode): Result[Account, string] =
  let accNodeRlp = rlpFromBytes(accountTrieNode.asSeq()).expectOk()
  if accNodeRlp.isEmpty() or accNodeRlp.listLen().expectOk() != 2:
    return err("invalid account trie node - malformed")

  let accNodePrefixRlp = accNodeRlp.listElem(0).expectOk()
  if accNodePrefixRlp.isEmpty():
    return err("invalid account trie node - empty prefix")

  let (_, isLeaf, _) = decodePrefix(accNodePrefixRlp)
  if not isLeaf:
    return err("invalid account trie node - leaf prefix expected")

  decodeRlp(accNodeRlp.listElem(1).toBytes().expectOk(), Account)

func rlpDecodeContractTrieNode*(contractTrieNode: TrieNode): Result[UInt256, string] =
  let storageNodeRlp = rlpFromBytes(contractTrieNode.asSeq()).expectOk()
  if storageNodeRlp.isEmpty() or storageNodeRlp.listLen().expectOk() != 2:
    return err("invalid contract trie node - malformed")

  let storageNodePrefixRlp = storageNodeRlp.listElem(0).expectOk()
  if storageNodePrefixRlp.isEmpty():
    return err("invalid contract trie node - empty prefix")

  let (_, isLeaf, _) = decodePrefix(storageNodePrefixRlp)
  if not isLeaf:
    return err("invalid contract trie node - leaf prefix expected")

  decodeRlp(storageNodeRlp.listElem(1).toBytes().expectOk(), UInt256)

func toAccount*(accountProof: TrieProof): Result[Account, string] {.inline.} =
  doAssert(accountProof.len() > 1)

  rlpDecodeAccountTrieNode(accountProof[^1])

func toSlot*(storageProof: TrieProof): Result[UInt256, string] {.inline.} =
  doAssert(storageProof.len() > 1)

  rlpDecodeContractTrieNode(storageProof[^1])

func toPath*(hash: KeccakHash): Nibbles {.inline.} =
  Nibbles.init(hash.data, isEven = true)

func toPath*(address: Address): Nibbles =
  keccakHash(address).toPath()

func toPath*(slotKey: UInt256): Nibbles =
  keccakHash(toBytesBE(slotKey)).toPath()
