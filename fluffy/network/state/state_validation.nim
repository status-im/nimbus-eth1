# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import eth/[common, trie], ../../common/common_types, ./state_content

proc isValidTrieNode(expectedHash: openArray[byte], node: TrieNode): bool {.inline.} =
  doAssert(expectedHash.len() == 32)
  expectedHash == keccakHash(node.asSeq()).data

proc isValidTrieNode(expectedHash: KeccakHash, node: TrieNode): bool {.inline.} =
  expectedHash == keccakHash(node.asSeq())

proc isValidBytecode(expectedHash: KeccakHash, code: Bytecode): bool {.inline.} =
  expectedHash == keccakHash(code.asSeq())

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

# proc hexPrefixDecode*(r: openArray[byte]): tuple[isLeaf: bool, nibbles: NibblesSeq] =
#   result.nibbles = initNibbleRange(r)
#   if r.len > 0:
#     result.isLeaf = (r[0] and 0x20) != 0
#     let hasOddLen = (r[0] and 0x10) != 0
#     result.nibbles.ibegin = 2 - int(hasOddLen)
#   else:
#     result.isLeaf = false

# template extensionNodeKey(r: Rlp): auto =
#   hexPrefixDecode r.listElem(0).toBytes

# Needs to handle partial path or full address path
proc isValidTrieProof(
    expectedRootHash: KeccakHash, path: Nibbles, proof: TrieProof
): bool =
  if proof.len() == 0:
    echo "Empty proof"
    return false

  if not isValidTrieNode(expectedRootHash, proof[0]):
    echo "Invalid root hash"
    return false

  let nibbles = path.unpackNibbles()
  if nibbles.len() == 0:
    if proof.len() == 1:
      echo "Empty path"
      return true
    else:
      echo "Invalid path"
      return false # root node case, already validated above

  var nibbleIdx = 0
  var proofIdx = 0

  while nibbleIdx < nibbles.len() and proofIdx < proof.len() - 1:
    let nextNibble = nibbles[nibbleIdx]
    let thisNode = proof[proofIdx]
    let nextNode = proof[proofIdx + 1]

    let nodeRlp = rlpFromBytes(thisNode.asSeq())
    if not nodeRlp.hasData or nodeRlp.isEmpty:
      echo "Invalid node"
      return false

    case nodeRlp.listLen()
    of 2:
      let nodePrefixRlp = nodeRlp.listElem(0)
      if nodePrefixRlp.isEmpty:
        echo "Invalid node prefix"
        return false

      let nodePrefix = nodePrefixRlp.toBytes()
      let firstN = (nodePrefix[0] and 0xF0) shr 4
      if firstN > 3:
        echo "Invalid node prefix"
        return false

      let isLeaf = firstN == 2 or firstN == 3
      let isEvenLen = firstN == 0 or firstN == 2

      # TODO: assuming only single byte prefixes for now
      let nextByte =
        if isEvenLen:
          nodePrefix[1]
        else:
          nodePrefix[0] and 0x0F
      if nextByte != nextNibble:
        echo "nextByte not matching"
        return false

      if isLeaf:
        if proofIdx < proof.len() - 1:
          echo "leaf not at end"
          return false
      else: # is extension node
        let nextHashRlp = nodeRlp.listElem(1)
        if nextHashRlp.isEmpty:
          echo "empty next hash"
          return false

        let nextHash = nextHashRlp.toBytes()
        if nextHash.len() != 32:
          echo "next hash wrong len"
          return false

        # echo "nextHash: ", nextHash
        # echo "nextNode: ", nextNode
        if not isValidTrieNode(nextHash, nextNode):
          return false
    of 17:
      if nextNibble >= 16:
        echo "Invalid branch node nibble"
        return false

      let nextHashRlp = nodeRlp.listElem(nextNibble.int)
      if nextHashRlp.isEmpty:
        echo "empty next hash"
        return false

      let nextHash = nextHashRlp.toBytes()
      if nextHash.len() != 32:
        echo "next hash wrong len"
        return false

      # echo "nextHash: ", nextHash
      # echo "nextNode: ", nextNode
      if not isValidTrieNode(nextHash, nextNode):
        echo "next hash invalid"
        return false
    else:
      echo "corrupt rlp"
      return false

    inc nibbleIdx
    inc proofIdx

  return true

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

  let account = decodeRlp(contractTrieNode.accountProof[^1].asSeq(), Account).valueOr:
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

  let account = decodeRlp(contractCode.accountProof[^1].asSeq(), Account).valueOr:
    return false

  isValidBytecode(account.codeHash, contractCode.code)
