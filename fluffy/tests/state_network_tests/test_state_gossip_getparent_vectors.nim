# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, strutils],
  results,
  unittest2,
  stew/byteutils,
  eth/common,
  ../../common/common_utils,
  ../../network/state/[state_content, state_gossip],
  ./state_test_helpers

suite "State Gossip getParent - Test Vectors":
  test "Check account trie node parent matches expected recursive gossip":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let key = ContentKey.decode(testData.content_key.hexToSeqByte().ByteList).get()
      let offer =
        AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      if i == 1: # second test case only has root node and no recursive gossip
        doAssertRaises(AssertionDefect):
          discard offer.withKey(key.accountTrieNodeKey).getParent()
        continue

      let (parentKey, parentOffer) = offer.withKey(key.accountTrieNodeKey).getParent()
      check:
        parentKey.path.unpackNibbles().len() <
          key.accountTrieNodeKey.path.unpackNibbles().len()
        parentOffer.proof.len() == offer.proof.len() - 1
        parentKey.toContentKey().encode() ==
          testData.recursive_gossip.content_key.hexToSeqByte().ByteList
        parentOffer.encode() ==
          testData.recursive_gossip.content_value_offer.hexToSeqByte()
        parentOffer.toRetrievalValue().encode() ==
          testData.recursive_gossip.content_value_retrieval.hexToSeqByte()

  test "Check contract storage trie node parent matches expected recursive gossip":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let key = ContentKey.decode(testData.content_key.hexToSeqByte().ByteList).get()
      let offer =
        ContractTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      if i == 1: # second test case only has root node and no recursive gossip
        doAssertRaises(AssertionDefect):
          discard offer.withKey(key.contractTrieNodeKey).getParent()
        continue

      let (parentKey, parentOffer) = offer.withKey(key.contractTrieNodeKey).getParent()
      check:
        parentKey.path.unpackNibbles().len() <
          key.contractTrieNodeKey.path.unpackNibbles().len()
        parentOffer.storageProof.len() == offer.storageProof.len() - 1
        parentKey.toContentKey().encode() ==
          testData.recursive_gossip.content_key.hexToSeqByte().ByteList
        parentOffer.encode() ==
          testData.recursive_gossip.content_value_offer.hexToSeqByte()
        parentOffer.toRetrievalValue().encode() ==
          testData.recursive_gossip.content_value_retrieval.hexToSeqByte()

  test "Check each account trie node parent matches expected recursive gossip":
    const file = testVectorDir / "recursive_gossip.yaml"

    let testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i == 1:
        continue

      for j in 0 ..< testData.recursive_gossip.high:
        let
          key = ContentKey
            .decode(testData.recursive_gossip[j].content_key.hexToSeqByte().ByteList)
            .get()
          offer = AccountTrieNodeOffer
            .decode(testData.recursive_gossip[j].content_value.hexToSeqByte())
            .get()
          (parentKey, parentOffer) = offer.withKey(key.accountTrieNodeKey).getParent()

        check:
          parentKey.path.unpackNibbles().len() <
            key.accountTrieNodeKey.path.unpackNibbles().len()
          parentOffer.proof.len() == offer.proof.len() - 1
          parentKey.toContentKey().encode() ==
            testData.recursive_gossip[j + 1].content_key.hexToSeqByte().ByteList
          parentOffer.encode() ==
            testData.recursive_gossip[j + 1].content_value.hexToSeqByte()

  test "Check each contract trie node parent matches expected recursive gossip":
    const file = testVectorDir / "recursive_gossip.yaml"

    let testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i != 1:
        continue

      for j in 0 ..< testData.recursive_gossip.high:
        let
          key = ContentKey
            .decode(testData.recursive_gossip[j].content_key.hexToSeqByte().ByteList)
            .get()
          offer = ContractTrieNodeOffer
            .decode(testData.recursive_gossip[j].content_value.hexToSeqByte())
            .get()
          (parentKey, parentOffer) = offer.withKey(key.contractTrieNodeKey).getParent()

        check:
          parentKey.path.unpackNibbles().len() <
            key.contractTrieNodeKey.path.unpackNibbles().len()
          parentOffer.storageProof.len() == offer.storageProof.len() - 1
          parentKey.toContentKey().encode() ==
            testData.recursive_gossip[j + 1].content_key.hexToSeqByte().ByteList
          parentOffer.encode() ==
            testData.recursive_gossip[j + 1].content_value.hexToSeqByte()
