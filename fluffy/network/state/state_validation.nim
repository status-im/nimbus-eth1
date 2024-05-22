# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  results,
  eth/[common, trie],
  ../../common/[common_types, common_utils],
  ./state_content

export results, state_content

# private functions

proc hashEquals(value: TrieNode | Bytecode, expectedHash: KeccakHash): bool {.inline.} =
  keccakHash(value.asSeq()) == expectedHash

proc isValidNextNode(thisNodeRlp: Rlp, rlpIdx: int, nextNode: TrieNode): bool =
  let hashOrShortRlp = thisNodeRlp.listElem(rlpIdx)
  if hashOrShortRlp.isEmpty():
    return false

  let nextHash =
    if hashOrShortRlp.isList():
      # is a short node
      keccakHash(rlp.encode(hashOrShortRlp))
    else:
      let hash = hashOrShortRlp.toBytes()
      if hash.len() != 32:
        return false
      KeccakHash.fromBytes(hash)

  nextNode.hashEquals(nextHash)

proc decodePrefix(nodePrefixRlp: Rlp): (byte, bool, Nibbles) =
  doAssert(not nodePrefixRlp.isEmpty())

  let
    rlpBytes = nodePrefixRlp.toBytes()
    firstNibble = (rlpBytes[0] and 0xF0) shr 4
    isLeaf = firstNibble == 2 or firstNibble == 3
    isEven = firstNibble == 0 or firstNibble == 2
    startIdx = if isEven: 1 else: 0
    nibbles = Nibbles.init(rlpBytes[startIdx .. ^1], isEven)

  (firstNibble.byte, isLeaf, nibbles)

proc rlpDecodeAccountTrieNode(accountNode: TrieNode): Result[Account, string] =
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

# public functions

proc validateTrieProof*(
    expectedRootHash: KeccakHash, path: Nibbles, proof: TrieProof
): Result[void, string] =
  if proof.len() == 0:
    return err("proof is empty")

  if not proof[0].hashEquals(expectedRootHash):
    return err("hash of proof root node doesn't match the expected root hash")

  let nibbles = path.unpackNibbles()
  if nibbles.len() == 0:
    if proof.len() == 1:
      return ok() # root node case, already validated above
    else:
      return err("empty path, only one node expected in proof")

  var nibbleIdx = 0
  for proofIdx, p in proof:
    let
      thisNodeRlp = rlpFromBytes(p.asSeq())
      remainingNibbles = nibbles.len() - nibbleIdx
      isLastNode = proofIdx == proof.high

    if remainingNibbles == 0:
      if isLastNode:
        break
      else:
        return err("empty nibbles but proof has more nodes")

    case thisNodeRlp.listLen()
    of 2:
      let nodePrefixRlp = thisNodeRlp.listElem(0)
      if nodePrefixRlp.isEmpty():
        return err("node prefix is empty")

      let (prefix, isLeaf, prefixNibbles) = decodePrefix(nodePrefixRlp)
      if prefix >= 4:
        return err("invalid prefix in node")

      if not isLastNode or isLeaf:
        let unpackedPrefix = prefixNibbles.unpackNibbles()
        if remainingNibbles < unpackedPrefix.len():
          return err("not enough nibbles to validate node prefix")

        let nibbleEndIdx = nibbleIdx + unpackedPrefix.len()
        if nibbles[nibbleIdx ..< nibbleEndIdx] != unpackedPrefix:
          return err("nibbles don't match node prefix")
        nibbleIdx += unpackedPrefix.len()

      if not isLastNode:
        if isLeaf:
          return err("leaf node must be last node in the proof")
        else: # is extension node
          if not isValidNextNode(thisNodeRlp, 1, proof[proofIdx + 1]):
            return
              err("hash of next node doesn't match the expected extension node hash")
    of 17:
      if not isLastNode:
        let nextNibble = nibbles[nibbleIdx]
        if nextNibble >= 16:
          return err("invalid next nibble for branch node")

        if not isValidNextNode(thisNodeRlp, nextNibble.int, proof[proofIdx + 1]):
          return err("hash of next node doesn't match the expected branch node hash")

        inc nibbleIdx
    else:
      return err("invalid rlp node, expected 2 or 17 elements")

  if nibbleIdx < nibbles.len():
    err("path contains more nibbles than expected for proof")
  else:
    ok()

proc validateRetrieval*(
    trustedAccountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeRetrieval,
): Result[void, string] =
  if accountTrieNode.node.hashEquals(trustedAccountTrieNodeKey.nodeHash):
    ok()
  else:
    err("hash of fetched account trie node doesn't match the expected node hash")

proc validateRetrieval*(
    trustedContractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeRetrieval,
): Result[void, string] =
  if contractTrieNode.node.hashEquals(trustedContractTrieNodeKey.nodeHash):
    ok()
  else:
    err("hash of fetched contract trie node doesn't match the expected node hash")

proc validateRetrieval*(
    trustedContractCodeKey: ContractCodeKey, contractCode: ContractCodeRetrieval
): Result[void, string] =
  if contractCode.code.hashEquals(trustedContractCodeKey.codeHash):
    ok()
  else:
    err("hash of fetched bytecode doesn't match the expected code hash")

proc validateOffer*(
    trustedStateRoot: KeccakHash,
    accountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeOffer,
): Result[void, string] =
  ?validateTrieProof(trustedStateRoot, accountTrieNodeKey.path, accountTrieNode.proof)

  if accountTrieNode.proof[^1].hashEquals(accountTrieNodeKey.nodeHash):
    ok()
  else:
    err("hash of offered account trie node doesn't match the expected node hash")

proc validateOffer*(
    trustedStateRoot: KeccakHash,
    contractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeOffer,
): Result[void, string] =
  let addressHash = keccakHash(contractTrieNodeKey.address).data
  ?validateTrieProof(
    trustedStateRoot, Nibbles.init(addressHash, true), contractTrieNode.accountProof
  )

  let account = ?rlpDecodeAccountTrieNode(contractTrieNode.accountProof[^1])

  ?validateTrieProof(
    account.storageRoot, contractTrieNodeKey.path, contractTrieNode.storageProof
  )

  if contractTrieNode.storageProof[^1].hashEquals(contractTrieNodeKey.nodeHash):
    ok()
  else:
    err("hash of offered contract trie node doesn't match the expected node hash")

proc validateOffer*(
    trustedStateRoot: KeccakHash,
    contractCodeKey: ContractCodeKey,
    contractCode: ContractCodeOffer,
): Result[void, string] =
  let addressHash = keccakHash(contractCodeKey.address).data
  ?validateTrieProof(
    trustedStateRoot, Nibbles.init(addressHash, true), contractCode.accountProof
  )

  let account = ?rlpDecodeAccountTrieNode(contractCode.accountProof[^1])

  if contractCode.code.hashEquals(account.codeHash):
    ok()
  else:
    err("hash of offered bytecode doesn't match the expected code hash")
