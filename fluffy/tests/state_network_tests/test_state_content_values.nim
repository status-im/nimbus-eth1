# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sugar, sequtils],
  testutils/unittests,
  stew/[byteutils, io2],
  eth/keys,
  ./helpers,
  ../../network/state/state_content,
  ../../eth_data/history_data_json_store

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/"

suite "State Content Values":
  test "Encode/decode AccountTrieNodeOffer":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      accountTrieNode = readJsonType(
        testVectorDir & "account_trie_node.json", JsonAccountTrieNode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error
      blockHash = BlockHash.fromHex(blockContent.`block`.block_hash)
      proof = TrieProof.init(
        blockContent.account_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      accountTrieNodeOffer = AccountTrieNodeOffer(blockHash: blockHash, proof: proof)

      encoded = SSZ.encode(accountTrieNodeOffer)
      expected = accountTrieNode.content_value_offer.hexToSeqByte()
      decoded = SSZ.decode(encoded, AccountTrieNodeOffer)

    check encoded == expected
    check decoded == accountTrieNodeOffer

  test "Encode/decode AccountTrieNodeRetrieval":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      accountTrieNode = readJsonType(
        testVectorDir & "account_trie_node.json", JsonAccountTrieNode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error

      node = TrieNode.init(blockContent.account_proof[^1].hexToSeqByte())
      accountTrieNodeRetrieval = AccountTrieNodeRetrieval(node: node)

      encoded = SSZ.encode(accountTrieNodeRetrieval)
      expected = accountTrieNode.content_value_retrieval.hexToSeqByte()
      decoded = SSZ.decode(encoded, AccountTrieNodeRetrieval)

    check encoded == expected
    check decoded == accountTrieNodeRetrieval

  test "Encode/decode ContractTrieNodeOffer":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      contractStorageTrieNode = readJsonType(
        testVectorDir & "contract_storage_trie_node.json", JsonContractStorageTtrieNode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error

      blockHash = BlockHash.fromHex(blockContent.`block`.block_hash)
      storageProof = TrieProof.init(
        blockContent.storage_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      accountProof = TrieProof.init(
        blockContent.account_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      contractTrieNodeOffer = ContractTrieNodeOffer(
        blockHash: blockHash, storage_proof: storageProof, account_proof: accountProof
      )

      encoded = SSZ.encode(contractTrieNodeOffer)
      expected = contractStorageTrieNode.content_value_offer.hexToSeqByte()
      decoded = SSZ.decode(encoded, ContractTrieNodeOffer)

    check encoded == expected
    check decoded == contractTrieNodeOffer

  test "Encode/decode ContractTrieNodeRetrieval":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      contractStorageTrieNode = readJsonType(
        testVectorDir & "contract_storage_trie_node.json", JsonContractStorageTtrieNode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error

      node = TrieNode.init(blockContent.storage_proof[^1].hexToSeqByte())
      contractTrieNodeRetrieval = ContractTrieNodeRetrieval(node: node)

      encoded = SSZ.encode(contractTrieNodeRetrieval)
      expected = contractStorageTrieNode.content_value_retrieval.hexToSeqByte()
      decoded = SSZ.decode(encoded, ContractTrieNodeRetrieval)

    check encoded == expected
    check decoded == contractTrieNodeRetrieval

  test "Encode/decode ContractCodeOffer":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      contractBytecode = readJsonType(
        testVectorDir & "contract_bytecode.json", JsonContractBytecode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error

      code = Bytecode.init(blockContent.bytecode.hexToSeqByte())
      blockHash = BlockHash.fromHex(blockContent.`block`.block_hash)
      accountProof = TrieProof.init(
        blockContent.account_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      contractCodeOffer =
        ContractCodeOffer(code: code, blockHash: blockHash, accountProof: accountProof)

      encoded = SSZ.encode(contractCodeOffer)
      expected = contractBytecode.content_value_offer.hexToSeqByte()
      decoded = SSZ.decode(encoded, ContractCodeOffer)

    check encoded == expected
    check decoded == contractCodeOffer

  test "Encode/decode ContractCodeRetrieval":
    let
      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      contractBytecode = readJsonType(
        testVectorDir & "contract_bytecode.json", JsonContractBytecode
      ).valueOr:
        raiseAssert "Cannot read test vector: " & error

      code = Bytecode.init(blockContent.bytecode.hexToSeqByte())
      contractCodeRetrieval = ContractCodeRetrieval(code: code)

      encoded = SSZ.encode(contractCodeRetrieval)
      expected = contractBytecode.content_value_retrieval.hexToSeqByte()
      decoded = SSZ.decode(encoded, ContractCodeRetrieval)

    check encoded == expected
    check decoded == contractCodeRetrieval
