# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  unittest2,
  stew/byteutils,
  ../../network/state/state_content,
  ../../network/state/state_validation,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

type YamlTrieNodeRecursiveGossipKV = ref object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string

type YamlTrieNodeKV = object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string
  recursive_gossip: YamlTrieNodeRecursiveGossipKV

type YamlTrieNodeKVs = seq[YamlTrieNodeKV]

type YamlContractBytecodeKV = object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string

type YamlContractBytecodeKVs = seq[YamlContractBytecodeKV]

suite "State Validation":
  test "Validate valid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      check:
        validateFetchedAccountTrieNode(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        )

  test "Validate invalid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      check:
        not validateFetchedAccountTrieNode(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        )

  test "Validate valid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractTrieNodeRetrieval
      )

      check:
        validateFetchedContractTrieNode(
          contentKey.contractTrieNodeKey, contentValueRetrieval
        )

  test "Validate invalid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractTrieNodeRetrieval
      )

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      check:
        not validateFetchedContractTrieNode(
          contentKey.contractTrieNodeKey, contentValueRetrieval
        )

  test "Validate valid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractCodeRetrieval
      )

      check:
        validateFetchedContractCode(contentKey.contractCodeKey, contentValueRetrieval)

  test "Validate invalid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractCodeRetrieval
      )

      contentValueRetrieval.code[^1] += 1 # Modify node hash

      check:
        not validateFetchedContractCode(
          contentKey.contractCodeKey, contentValueRetrieval
        )
