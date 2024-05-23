# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import results, eth/common, ./state_content

export results, common

proc decodePrefix*(nodePrefixRlp: Rlp): (byte, bool, Nibbles) =
  doAssert(not nodePrefixRlp.isEmpty())

  let
    rlpBytes = nodePrefixRlp.toBytes()
    firstNibble = (rlpBytes[0] and 0xF0) shr 4
    isLeaf = firstNibble == 2 or firstNibble == 3
    isEven = firstNibble == 0 or firstNibble == 2
    startIdx = if isEven: 1 else: 0
    nibbles = Nibbles.init(rlpBytes[startIdx .. ^1], isEven)

  (firstNibble.byte, isLeaf, nibbles)

proc rlpDecodeAccountTrieNode*(accountNode: TrieNode): Result[Account, string] =
  let accNodeRlp = rlpFromBytes(accountNode.asSeq())
  if accNodeRlp.isEmpty() or accNodeRlp.listLen() != 2:
    return err("invalid account trie node - malformed")

  let accNodePrefixRlp = accNodeRlp.listElem(0)
  if accNodePrefixRlp.isEmpty():
    return err("invalid account trie node - empty prefix")

  let (_, isLeaf, _) = decodePrefix(accNodePrefixRlp)
  if not isLeaf:
    return err("invalid account trie node - leaf prefix expected")

  decodeRlp(accNodeRlp.listElem(1).toBytes(), Account)
