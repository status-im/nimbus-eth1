# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, sugar, sequtils],
  unittest2,
  stew/byteutils,
  ../../network/state/state_content,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/serialization/"

suite "State Content Values":
  test "Encode/decode AccountTrieNodeOffer":
    const file = testVectorDir / "account_trie_node_with_proof.yaml"

    type YamlAccountTrieNodeWithProof = object
      proof: seq[string]
      block_hash: string
      content_value: string

    let
      testCase = YamlAccountTrieNodeWithProof.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      blockHash = Hash32.fromHex(testCase.block_hash)
      proof =
        TrieProof.init(testCase.proof.map((hex) => TrieNode.init(hex.hexToSeqByte())))
      accountTrieNodeOffer = AccountTrieNodeOffer.init(proof, blockHash)

      encoded = accountTrieNodeOffer.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = AccountTrieNodeOffer.decode(encoded).get()

    check:
      encoded == expected
      decoded == accountTrieNodeOffer

  test "Encode/decode AccountTrieNodeRetrieval":
    const file = testVectorDir / "trie_node.yaml"

    type YamlTrieNode = object
      trie_node: string
      content_value: string

    let
      testCase = YamlTrieNode.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      node = TrieNode.init(testCase.trie_node.hexToSeqByte())
      accountTrieNodeRetrieval = AccountTrieNodeRetrieval(node: node)

      encoded = accountTrieNodeRetrieval.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = AccountTrieNodeRetrieval.decode(encoded).get()

    check:
      encoded == expected
      decoded == accountTrieNodeRetrieval

  test "Encode/decode ContractTrieNodeOffer":
    const file = testVectorDir / "contract_storage_trie_node_with_proof.yaml"

    type YamlContractStorageTrieNodeWithProof = object
      storage_proof: seq[string]
      account_proof: seq[string]
      block_hash: string
      content_value: string

    let
      testCase = YamlContractStorageTrieNodeWithProof.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      blockHash = Hash32.fromHex(testCase.block_hash)
      storageProof = TrieProof.init(
        testCase.storage_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      accountProof = TrieProof.init(
        testCase.account_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      contractTrieNodeOffer = ContractTrieNodeOffer(
        blockHash: blockHash, storage_proof: storageProof, account_proof: accountProof
      )

      encoded = contractTrieNodeOffer.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = ContractTrieNodeOffer.decode(encoded).get()

    check:
      encoded == expected
      decoded == contractTrieNodeOffer

  test "Encode/decode ContractTrieNodeRetrieval":
    # TODO: This is practically the same as AccountTrieNodeRetrieval test,
    # but we use different objects for it. Might want to adjust this to just
    # 1 basic TrieNode type.
    const file = testVectorDir / "trie_node.yaml"

    type YamlTrieNode = object
      trie_node: string
      content_value: string

    let
      testCase = YamlTrieNode.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      node = TrieNode.init(testCase.trie_node.hexToSeqByte())
      contractTrieNodeRetrieval = ContractTrieNodeRetrieval(node: node)

      encoded = contractTrieNodeRetrieval.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = ContractTrieNodeRetrieval.decode(encoded).get()

    check:
      encoded == expected
      decoded == contractTrieNodeRetrieval

  test "Encode/decode ContractCodeOffer":
    const file = testVectorDir / "contract_bytecode_with_proof.yaml"

    type YamlContractBytecodeWithProof = object
      bytecode: string
      account_proof: seq[string]
      block_hash: string
      content_value: string

    let
      testCase = YamlContractBytecodeWithProof.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      code = Bytecode.init(testCase.bytecode.hexToSeqByte())
      blockHash = Hash32.fromHex(testCase.block_hash)
      accountProof = TrieProof.init(
        testCase.account_proof.map((hex) => TrieNode.init(hex.hexToSeqByte()))
      )
      contractCodeOffer =
        ContractCodeOffer(code: code, blockHash: blockHash, accountProof: accountProof)

      encoded = contractCodeOffer.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = ContractCodeOffer.decode(encoded).get()

    check:
      encoded == expected
      decoded == contractCodeOffer

  test "Encode/decode ContractCodeRetrieval":
    const file = testVectorDir / "contract_bytecode.yaml"

    type YamlContractBytecode = object
      bytecode: string
      content_value: string

    let
      testCase = YamlContractBytecode.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      code = Bytecode.init(testCase.bytecode.hexToSeqByte())
      contractCodeRetrieval = ContractCodeRetrieval(code: code)

      encoded = contractCodeRetrieval.encode()
      expected = testCase.content_value.hexToSeqByte()
      decoded = ContractCodeRetrieval.decode(encoded).get()

    check:
      encoded == expected
      decoded == contractCodeRetrieval
