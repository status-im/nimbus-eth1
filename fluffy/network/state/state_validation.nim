# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import eth/[common, trie], eth/trie/[hexary, db, trie_defs], ./state_content

proc validateFetchedAccountTrieNode*(
    trustedAccountTrieNodeKey: AccountTrieNodeKey,
    accountTrieNode: AccountTrieNodeRetrieval,
): bool =
  let expectedHash = trustedAccountTrieNodeKey.nodeHash
  let actualHash = keccakHash(accountTrieNode.node.asSeq())

  expectedHash == actualHash

proc validateFetchedContractTrieNode*(
    trustedContractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeRetrieval,
): bool =
  let expectedHash = trustedContractTrieNodeKey.nodeHash
  let actualHash = keccakHash(contractTrieNode.node.asSeq())

  expectedHash == actualHash

proc validateFetchedContractCode*(
    trustedContractCodeKey: ContractCodeKey, contractCode: ContractCodeRetrieval
): bool =
  let expectedHash = trustedContractCodeKey.codeHash
  let actualHash = keccakHash(contractCode.code.asSeq())

  expectedHash == actualHash

# TODO: implement generic validation path walking proof verification

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

  # verify account proof

  false

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

  # verify account proof
  # get storage root from account leaf
  # verify storage proof

  false

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

  # verify account proof
  # get codehash from account leaf
  # verify codehash

  false
