# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import results, eth/common/eth_types, ssz_serialization, ../../../common/common_types

export ssz_serialization, common_types, hash, results

const
  MAX_TRIE_NODE_LEN = 1024
  MAX_TRIE_PROOF_LEN = 65
  MAX_BYTECODE_LEN = 32768

type
  TrieNode* = List[byte, MAX_TRIE_NODE_LEN]
  TrieProof* = List[TrieNode, MAX_TRIE_PROOF_LEN]
  Bytecode* = List[byte, MAX_BYTECODE_LEN]

  AccountTrieNodeOffer* = object
    proof*: TrieProof
    blockHash*: BlockHash

  AccountTrieNodeRetrieval* = object
    node*: TrieNode

  ContractTrieNodeOffer* = object
    storageProof*: TrieProof
    accountProof*: TrieProof
    blockHash*: BlockHash

  ContractTrieNodeRetrieval* = object
    node*: TrieNode

  ContractCodeOffer* = object
    code*: Bytecode
    accountProof*: TrieProof
    blockHash*: BlockHash

  ContractCodeRetrieval* = object
    code*: Bytecode

  ContentValue* =
    AccountTrieNodeOffer | ContractTrieNodeOffer | ContractCodeOffer |
    AccountTrieNodeRetrieval | ContractTrieNodeRetrieval | ContractCodeRetrieval

func init*(T: type AccountTrieNodeOffer, proof: TrieProof, blockHash: BlockHash): T =
  AccountTrieNodeOffer(proof: proof, blockHash: blockHash)

func init*(T: type AccountTrieNodeRetrieval, node: TrieNode): T =
  AccountTrieNodeRetrieval(node: node)

func init*(
    T: type ContractTrieNodeOffer,
    storageProof: TrieProof,
    accountProof: TrieProof,
    blockHash: BlockHash,
): T =
  ContractTrieNodeOffer(
    storageProof: storageProof, accountProof: accountProof, blockHash: blockHash
  )

func init*(T: type ContractTrieNodeRetrieval, node: TrieNode): T =
  ContractTrieNodeRetrieval(node: node)

func init*(
    T: type ContractCodeOffer,
    code: Bytecode,
    accountProof: TrieProof,
    blockHash: BlockHash,
): T =
  ContractCodeOffer(code: code, accountProof: accountProof, blockHash: blockHash)

func init*(T: type ContractCodeRetrieval, code: Bytecode): T =
  ContractCodeRetrieval(code: code)

func toRetrievalValue*(offer: AccountTrieNodeOffer): AccountTrieNodeRetrieval =
  AccountTrieNodeRetrieval.init(offer.proof[^1])

func toRetrievalValue*(offer: ContractTrieNodeOffer): ContractTrieNodeRetrieval =
  ContractTrieNodeRetrieval.init(offer.storageProof[^1])

func toRetrievalValue*(offer: ContractCodeOffer): ContractCodeRetrieval =
  ContractCodeRetrieval.init(offer.code)

func encode*(value: ContentValue): seq[byte] =
  SSZ.encode(value)

func decode*(T: type ContentValue, bytes: openArray[byte]): Result[T, string] =
  decodeSsz(bytes, T)
