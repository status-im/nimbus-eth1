# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  results,
  unittest2,
  stew/byteutils,
  ../../network/state/[state_content, state_gossip],
  ./state_test_helpers

suite "State Gossip getParent - Test Vectors":
  test "Check account trie node parent matches expected recursive gossip":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i == 0 or i == 3:
        let
          parentTestData = testCase[i + 1]
          key = ContentKey
            .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
            .get()
          offer = AccountTrieNodeOffer
            .decode(testData.content_value_offer.hexToSeqByte())
            .get()

        let (parentKey, parentOffer) = offer.withKey(key.accountTrieNodeKey).getParent()
        check:
          parentKey.path.unpackNibbles().len() <
            key.accountTrieNodeKey.path.unpackNibbles().len()
          parentOffer.proof.len() == offer.proof.len() - 1
          parentKey.toContentKey().encode() ==
            parentTestData.content_key.hexToSeqByte().ContentKeyByteList
          parentOffer.encode() == parentTestData.content_value_offer.hexToSeqByte()
          parentOffer.toRetrieval().encode() ==
            parentTestData.content_value_retrieval.hexToSeqByte()

  test "Check contract storage trie node parent matches expected recursive gossip":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i == 0:
        let
          parentTestData = testCase[i + 1]
          key = ContentKey
            .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
            .get()
          offer = ContractTrieNodeOffer
            .decode(testData.content_value_offer.hexToSeqByte())
            .get()

        let (parentKey, parentOffer) =
          offer.withKey(key.contractTrieNodeKey).getParent()
        check:
          parentKey.path.unpackNibbles().len() <
            key.contractTrieNodeKey.path.unpackNibbles().len()
          parentOffer.storageProof.len() == offer.storageProof.len() - 1
          parentKey.toContentKey().encode() ==
            parentTestData.content_key.hexToSeqByte().ContentKeyByteList
          parentOffer.encode() == parentTestData.content_value_offer.hexToSeqByte()
          parentOffer.toRetrieval().encode() ==
            parentTestData.content_value_retrieval.hexToSeqByte()
