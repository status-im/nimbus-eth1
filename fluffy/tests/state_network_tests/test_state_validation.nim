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
  ../../network/state/state_validation,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

type YamlAccountTrieNodeRecursiveGossip = ref object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string

type YamlAccountTrieNode = object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string
  recursive_gossip: YamlAccountTrieNodeRecursiveGossip

type YamlAccountTrieNodes = seq[YamlAccountTrieNode]

suite "State Validation":
  test "Validate valid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlAccountTrieNodes.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      check:
        validateAccountTrieNodeHash(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        ) == true

  test "Validate invalid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlAccountTrieNodes.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      check:
        validateAccountTrieNodeHash(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        ) == false
