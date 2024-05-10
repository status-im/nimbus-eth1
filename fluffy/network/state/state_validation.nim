# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import eth/[common, trie], ../../common/common_types, ./state_content

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

  var packedNibbles = Nibbles(@rlpBytes)
  if isEven:
    packedNibbles[0] = 0
  else:
    # set the first nibble to 1
    packedNibbles[0] = (packedNibbles[0] and 0x0F) or 0x10

  (firstNibble.byte, isLeaf, packedNibbles)

proc isValidTrieProof(
    expectedRootHash: KeccakHash, path: Nibbles, proof: TrieProof
): bool =
  if proof.len() == 0:
    return false

  if not isValidTrieNode(expectedRootHash, proof[0]):
    return false

  let nibbles = path.unpackNibbles()
  if nibbles.len() == 0:
    if proof.len() == 1:
      return true # root node case, already validated above
    else:
      return false

  var nibbleIdx = 0
  for proofIdx, p in proof[0 ..^ 2]:
    let
      thisNodeRlp = rlpFromBytes(p.asSeq())
      nextNode = proof[proofIdx + 1]
      remainingNibbles = nibbles.len() - nibbleIdx

    if remainingNibbles == 0:
      return false

    case thisNodeRlp.listLen()
    of 2:
      let nodePrefixRlp = thisNodeRlp.listElem(0)
      if nodePrefixRlp.isEmpty:
        return false

      let (prefix, isLeaf, prefixNibbles) = decodePrefix(nodePrefixRlp)
      if prefix >= 4:
        return false # invalid prefix

      let unpackedPrefix = prefixNibbles.unpackNibbles()
      if remainingNibbles < unpackedPrefix.len():
        return false # not enough nibbles for prefix

      let nibbleEndIdx = nibbleIdx + unpackedPrefix.len()
      if nibbles[nibbleIdx ..< nibbleEndIdx] != unpackedPrefix:
        return false
      nibbleIdx += unpackedPrefix.len()

      if isLeaf:
        if proofIdx < proof.len() - 1:
          return false # leaf should be the last node in the proof
      else: # is extension node
        if not isValidNextNode(thisNodeRlp, 1, nextNode):
          return false
    of 17:
      let nextNibble = nibbles[nibbleIdx]
      if nextNibble >= 16 or not isValidNextNode(thisNodeRlp, nextNibble.int, nextNode):
        return false
      inc nibbleIdx
    else:
      return false

  return true

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
): bool =
  let expectedHash = trustedAccountTrieNodeKey.nodeHash
  isValidTrieNode(expectedHash, accountTrieNode.node)

proc validateFetchedContractTrieNode*(
    trustedContractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeRetrieval,
): bool =
  let expectedHash = trustedContractTrieNodeKey.nodeHash
  isValidTrieNode(expectedHash, contractTrieNode.node)

proc validateFetchedContractCode*(
    trustedContractCodeKey: ContractCodeKey, contractCode: ContractCodeRetrieval
): bool =
  let expectedHash = trustedContractCodeKey.codeHash
  isValidBytecode(expectedHash, contractCode.code)

# Precondition: AccountTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedAccountTrieNode*(
    trustedStateRoot: KeccakHash,
    accountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeOffer,
): bool =
  isValidTrieProof(trustedStateRoot, accountTrieNodeKey.path, accountTrieNode.proof) and
    isValidTrieNode(accountTrieNodeKey.nodeHash, accountTrieNode.proof[^1])

# Precondition: ContractTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractTrieNode*(
    trustedStateRoot: KeccakHash,
    contractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeOffer,
): bool =
  let
    addressHash = keccakHash(contractTrieNodeKey.address).data
    accountPath = Nibbles(@addressHash)
  if not isValidTrieProof(trustedStateRoot, accountPath, contractTrieNode.accountProof):
    return false

  let account = rlpDecodeAccountTrieNode(contractTrieNode.accountProof[^1]).valueOr:
    return false

  isValidTrieProof(
    account.storageRoot, contractTrieNodeKey.path, contractTrieNode.storageProof
  ) and isValidTrieNode(contractTrieNodeKey.nodeHash, contractTrieNode.storageProof[^1])

# Precondition: ContractCodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractCode*(
    trustedStateRoot: KeccakHash,
    contractCodeKey: ContractCodeKey,
    contractCode: ContractCodeOffer,
): bool =
  let
    addressHash = keccakHash(contractCodeKey.address).data
    accountPath = Nibbles(@addressHash)
  if not isValidTrieProof(trustedStateRoot, accountPath, contractCode.accountProof):
    return false

  let account = rlpDecodeAccountTrieNode(contractCode.accountProof[^1]).valueOr:
    return false

  isValidBytecode(account.codeHash, contractCode.code)
