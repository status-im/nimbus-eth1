# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import results, ssz_serialization, ../../../common/common_types

export ssz_serialization, common_types, hash, results

const
  MAX_TRIE_NODE_LEN* = 1024
  MAX_TRIE_PROOF_LEN* = 65
  MAX_BYTECODE_LEN* = 32768

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

  ContentOfferType* = AccountTrieNodeOffer | ContractTrieNodeOffer | ContractCodeOffer
  ContentRetrievalType* =
    AccountTrieNodeRetrieval | ContractTrieNodeRetrieval | ContractCodeRetrieval
  ContentValueType* = ContentOfferType | ContentRetrievalType

func init*(
    T: type AccountTrieNodeOffer, proof: TrieProof, blockHash: BlockHash
): T {.inline.} =
  T(proof: proof, blockHash: blockHash)

func init*(T: type AccountTrieNodeRetrieval, node: TrieNode): T {.inline.} =
  T(node: node)

func init*(
    T: type ContractTrieNodeOffer,
    storageProof: TrieProof,
    accountProof: TrieProof,
    blockHash: BlockHash,
): T {.inline.} =
  T(storageProof: storageProof, accountProof: accountProof, blockHash: blockHash)

func init*(T: type ContractTrieNodeRetrieval, node: TrieNode): T {.inline.} =
  T(node: node)

func init*(
    T: type ContractCodeOffer,
    code: Bytecode,
    accountProof: TrieProof,
    blockHash: BlockHash,
): T {.inline.} =
  T(code: code, accountProof: accountProof, blockHash: blockHash)

func init*(T: type ContractCodeRetrieval, code: Bytecode): T {.inline.} =
  T(code: code)

func toRetrievalValue*(
    offer: AccountTrieNodeOffer
): AccountTrieNodeRetrieval {.inline.} =
  AccountTrieNodeRetrieval.init(offer.proof[^1])

func toRetrievalValue*(
    offer: ContractTrieNodeOffer
): ContractTrieNodeRetrieval {.inline.} =
  ContractTrieNodeRetrieval.init(offer.storageProof[^1])

func toRetrievalValue*(offer: ContractCodeOffer): ContractCodeRetrieval {.inline.} =
  ContractCodeRetrieval.init(offer.code)

func empty*(T: type TrieProof): T {.inline.} =
  T.init(@[])

func empty*(T: type Bytecode): T {.inline.} =
  T(@[])

func encode*(value: ContentValueType): seq[byte] {.inline.} =
  SSZ.encode(value)

func decode*(
    T: type ContentValueType, bytes: openArray[byte]
): Result[T, string] {.inline.} =
  decodeSsz(bytes, T)
