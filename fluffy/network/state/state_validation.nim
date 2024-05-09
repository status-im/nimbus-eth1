# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import eth/[common, trie], eth/trie/[hexary, db, trie_defs], ./state_content

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

# Needs to handle partial path or full address path
proc isValidTrieProof(
    expectedRootHash: KeccakHash, path: Nibbles, proof: TrieProof
): bool =
  if proof.len() == 0:
    return false

  if not isValidTrieNode(expectedRootHash, proof[0]):
    return false

  # TODO: walk down the rest of the trie and check that each node is in the path of the proof

  # NOTE: this does not check the last node

  false

proc decodeAccount(leafNode: TrieNode): Account =
  # TODO: implement this
  #rlpFromBytes
  Account()

# Precondition: AccountTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedAccountTrieNode*(
    trustedStateRoot: KeccakHash,
    accountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeOffer,
): bool =
  # AccountTrieNodeKey* = object
  #   path*: Nibbles
  #   nodeHash*: NodeHash
  # AccountTrieNodeOffer* = object
  #   proof*: TrieProof
  #   blockHash*: BlockHash

  isValidTrieProof(trustedStateRoot, accountTrieNodeKey.path, accountTrieNode.proof) and
    isValidTrieNode(accountTrieNodeKey.nodeHash, accountTrieNode.proof[^1])

# Precondition: ContractTrieNodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractTrieNode*(
    trustedStateRoot: KeccakHash,
    contractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeOffer,
): bool =
  # ContractTrieNodeKey* = object
  #   address*: Address
  #   path*: Nibbles
  #   nodeHash*: NodeHash
  # ContractTrieNodeOffer* = object
  #   storageProof*: TrieProof
  #   accountProof*: TrieProof
  #   blockHash*: BlockHash

  let
    addressHash = keccakHash(contractTrieNodeKey.address).data
    accountPath = Nibbles(@addressHash)
  if not isValidTrieProof(trustedStateRoot, accountPath, contractTrieNode.accountProof):
    return false

  let account = decodeAccount(contractTrieNode.accountProof[^1])

  isValidTrieProof(
    account.storageRoot, contractTrieNodeKey.path, contractTrieNode.storageProof
  ) and isValidTrieNode(contractTrieNodeKey.nodeHash, contractTrieNode.storageProof[^1])

# Precondition: ContractCodeOffer.blockHash is already checked to be part of the canonical chain
proc validateOfferedContractCode*(
    trustedStateRoot: KeccakHash,
    contractCodeKey: ContractCodeKey,
    contractCode: ContractCodeOffer,
): bool =
  # ContractCodeKey* = object
  #   address*: Address
  #   codeHash*: CodeHash
  # ContractCodeOffer* = object
  #   code*: Bytecode
  #   accountProof*: TrieProof
  #   blockHash*: BlockHash

  let
    addressHash = keccakHash(contractCodeKey.address).data
    accountPath = Nibbles(@addressHash)
  if not isValidTrieProof(trustedStateRoot, accountPath, contractCode.accountProof):
    return false

  let account: Account = decodeAccount(contractCode.accountProof[^1])

  isValidBytecode(account.codeHash, contractCode.code)
