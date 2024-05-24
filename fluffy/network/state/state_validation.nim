# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import results, eth/common, ../../common/common_utils, ./state_content, ./state_utils

export results, state_content

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

proc validateTrieProof*(
    expectedRootHash: KeccakHash,
    path: Nibbles,
    proof: TrieProof,
    allowKeyEndInPathForLeafs = false,
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

      if not isLastNode or (isLeaf and allowKeyEndInPathForLeafs):
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
    key: AccountTrieNodeKey, value: AccountTrieNodeRetrieval
): Result[void, string] =
  if value.node.hashEquals(key.nodeHash):
    ok()
  else:
    err("hash of account trie node doesn't match the expected node hash")

proc validateRetrieval*(
    key: ContractTrieNodeKey, value: ContractTrieNodeRetrieval
): Result[void, string] =
  if value.node.hashEquals(key.nodeHash):
    ok()
  else:
    err("hash of contract trie node doesn't match the expected node hash")

proc validateRetrieval*(
    key: ContractCodeKey, value: ContractCodeRetrieval
): Result[void, string] =
  if value.code.hashEquals(key.codeHash):
    ok()
  else:
    err("hash of bytecode doesn't match the expected code hash")

proc validateOffer*(
    trustedStateRoot: KeccakHash, key: AccountTrieNodeKey, offer: AccountTrieNodeOffer
): Result[void, string] =
  ?validateTrieProof(trustedStateRoot, key.path, offer.proof)

  validateRetrieval(key, offer.toRetrievalValue())

proc validateOffer*(
    trustedStateRoot: KeccakHash, key: ContractTrieNodeKey, offer: ContractTrieNodeOffer
): Result[void, string] =
  let addressHash = keccakHash(key.address).data
  ?validateTrieProof(
    trustedStateRoot,
    Nibbles.init(addressHash, true),
    offer.accountProof,
    allowKeyEndInPathForLeafs = true,
  )

  let account = ?rlpDecodeAccountTrieNode(offer.accountProof[^1])

  ?validateTrieProof(account.storageRoot, key.path, offer.storageProof)

  validateRetrieval(key, offer.toRetrievalValue())

proc validateOffer*(
    trustedStateRoot: KeccakHash, key: ContractCodeKey, offer: ContractCodeOffer
): Result[void, string] =
  let addressHash = keccakHash(key.address).data
  ?validateTrieProof(
    trustedStateRoot,
    Nibbles.init(addressHash, true),
    offer.accountProof,
    allowKeyEndInPathForLeafs = true,
  )

  let account = ?rlpDecodeAccountTrieNode(offer.accountProof[^1])
  if not offer.code.hashEquals(account.codeHash):
    return err("hash of bytecode doesn't match the code hash in the account proof")

  validateRetrieval(key, offer.toRetrievalValue())
