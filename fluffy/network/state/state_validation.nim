# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import results, eth/[common, trie], ../../common/common_types, ./state_content

# private functions

proc isValidTrieNode(expectedHash: openArray[byte], node: TrieNode): bool {.inline.} =
  doAssert(expectedHash.len() == 32)
  expectedHash == keccakHash(node.asSeq()).data

proc isValidTrieNode(expectedHash: KeccakHash, node: TrieNode): bool {.inline.} =
  expectedHash == keccakHash(node.asSeq())

proc isValidBytecode(expectedHash: KeccakHash, code: Bytecode): bool {.inline.} =
  expectedHash == keccakHash(code.asSeq())

proc isValidNextNode(nodeRlp: Rlp, rlpIdx: int, nextNode: TrieNode): bool =
  let nextHashRlp = nodeRlp.listElem(rlpIdx)
  if nextHashRlp.isEmpty:
    return false

  let nextHash = nextHashRlp.toBytes()
  if nextHash.len() != 32:
    return false

  isValidTrieNode(nextHash, nextNode)

proc decodePrefix(nodePrefixRlp: Rlp): (byte, bool, Nibbles) =
  let
    rlpBytes = nodePrefixRlp.toBytes()
    firstNibble = (rlpBytes[0] and 0xF0) shr 4
    isLeaf = firstNibble == 2 or firstNibble == 3
    isEven = firstNibble == 0 or firstNibble == 2

  (firstNibble.byte, isLeaf, Nibbles.init(rlpBytes[isEven.int .. ^1]))

proc validateTrieProof(
    expectedRootHash: KeccakHash, path: Nibbles, proof: TrieProof
): Result[void, string] =
  if proof.len() == 0:
    return err("proof is empty")

  if not isValidTrieNode(expectedRootHash, proof[0]):
    return err("hash of proof root node doesn't match the expected root hash")

  let nibbles = path.unpackNibbles()
  if nibbles.len() == 0:
    if proof.len() == 1:
      return ok() # root node case, already validated above
    else:
      return err("empty path, only one node expected in proof")

  var nibbleIdx = 0
  for proofIdx, p in proof[0 ..^ 2]:
    let
      thisNodeRlp = rlpFromBytes(p.asSeq())
      nextNode = proof[proofIdx + 1]
      remainingNibbles = nibbles.len() - nibbleIdx

    if remainingNibbles == 0:
      return err("empty nibbles but proof has more nodes")

    case thisNodeRlp.listLen()
    of 2:
      let nodePrefixRlp = thisNodeRlp.listElem(0)
      if nodePrefixRlp.isEmpty:
        return err("node prefix is empty")

      let (prefix, isLeaf, prefixNibbles) = decodePrefix(nodePrefixRlp)
      if prefix >= 4:
        return err("invalid prefix in node")

      let unpackedPrefix = prefixNibbles.unpackNibbles()
      if remainingNibbles < unpackedPrefix.len():
        return err("not enough nibbles to validate node prefix")

      let nibbleEndIdx = nibbleIdx + unpackedPrefix.len()
      if nibbles[nibbleIdx ..< nibbleEndIdx] != unpackedPrefix:
        return err("nibbles don't match node prefix")
      nibbleIdx += unpackedPrefix.len()

      if isLeaf:
        if proofIdx < proof.len() - 1:
          return err("leaf node must be last node in the proof")
      else: # is extension node
        if not isValidNextNode(thisNodeRlp, 1, nextNode):
          return err("hash of next node doesn't match the expected extension node hash")
    of 17:
      let nextNibble = nibbles[nibbleIdx]
      if nextNibble >= 16:
        return err("invalid next nibble for branch node")

      if not isValidNextNode(thisNodeRlp, nextNibble.int, nextNode):
        return err("hash of next node doesn't match the expected branch node hash")

      inc nibbleIdx
    else:
      return err("invalid rlp node, expected 2 or 17 elements")

  ok()

proc rlpDecodeAccountTrieNode(accountNode: TrieNode): auto =
  let accNodeRlp = rlpFromBytes(accountNode.asSeq())
  doAssert(accNodeRlp.hasData and not accNodeRlp.isEmpty and accNodeRlp.listLen() == 2)

  let (_, isLeaf, _) = decodePrefix(accNodeRlp.listElem(0))
  doAssert(isLeaf)

  decodeRlp(accNodeRlp.listElem(1).toBytes(), Account)

# public functions

proc validateFetchedAccountTrieNode*(
    trustedAccountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeRetrieval,
): Result[void, string] =
  let expectedHash = trustedAccountTrieNodeKey.nodeHash
  if not isValidTrieNode(expectedHash, accountTrieNode.node):
    return err("hash of fetched account trie node doesn't match the expected node hash")

  ok()

proc validateFetchedContractTrieNode*(
    trustedContractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeRetrieval,
): Result[void, string] =
  let expectedHash = trustedContractTrieNodeKey.nodeHash
  if not isValidTrieNode(expectedHash, contractTrieNode.node):
    return
      err("hash of fetched contract trie node doesn't match the expected node hash")

  ok()

proc validateFetchedContractCode*(
    trustedContractCodeKey: ContractCodeKey, contractCode: ContractCodeRetrieval
): Result[void, string] =
  let expectedHash = trustedContractCodeKey.codeHash
  if not isValidBytecode(expectedHash, contractCode.code):
    return err("hash of fetched bytecode doesn't match the expected code hash")

  ok()

# Precondition: AccountTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedAccountTrieNode*(
    trustedStateRoot: KeccakHash,
    accountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeOffer,
): Result[void, string] =
  ?validateTrieProof(trustedStateRoot, accountTrieNodeKey.path, accountTrieNode.proof)

  if not isValidTrieNode(accountTrieNodeKey.nodeHash, accountTrieNode.proof[^1]):
    return err("hash of offered account trie node doesn't match the expected node hash")

  ok()

# Precondition: ContractTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractTrieNode*(
    trustedStateRoot: KeccakHash,
    contractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeOffer,
): Result[void, string] =
  let addressHash = keccakHash(contractTrieNodeKey.address).data
  ?validateTrieProof(
    trustedStateRoot, Nibbles.init(addressHash), contractTrieNode.accountProof
  )

  let account = ?rlpDecodeAccountTrieNode(contractTrieNode.accountProof[^1])

  ?validateTrieProof(
    account.storageRoot, contractTrieNodeKey.path, contractTrieNode.storageProof
  )

  if not isValidTrieNode(
    contractTrieNodeKey.nodeHash, contractTrieNode.storageProof[^1]
  ):
    return
      err("hash of offered contract trie node doesn't match the expected node hash")

  ok()

# Precondition: ContractCodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractCode*(
    trustedStateRoot: KeccakHash,
    contractCodeKey: ContractCodeKey,
    contractCode: ContractCodeOffer,
): Result[void, string] =
  let addressHash = keccakHash(contractCodeKey.address).data
  ?validateTrieProof(
    trustedStateRoot, Nibbles.init(addressHash), contractCode.accountProof
  )

  let account = ?rlpDecodeAccountTrieNode(contractCode.accountProof[^1])

  if not isValidBytecode(account.codeHash, contractCode.code):
    return err("hash of offered bytecode doesn't match the expected code hash")

  ok()