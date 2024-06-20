# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests,
  chronos,
  stew/byteutils,
  eth/common,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ../../common/common_utils,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/state/[state_content, state_network, state_gossip],
  ../../database/content_db,
  ./state_test_helpers

procSuite "State Gossip - Gossip Offer":
  const STATE_NODE1_PORT = 20602
  const STATE_NODE2_PORT = 20603

  let rng = newRng()

  asyncTest "Gossip account trie nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
      stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

    stateNode1.start()
    stateNode2.start()

    check:
      stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

    for i, testData in testCase:
      if i == 1:
        continue # skip scenario with no parent

      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()

        parentContentKeyBytes =
          testData.recursive_gossip.content_key.hexToSeqByte().ByteList
        parentContentKey = ContentKey.decode(parentContentKeyBytes).get()
        parentContentId = toContentId(parentContentKeyBytes)
        parentContentValueBytes =
          testData.recursive_gossip.content_value_offer.hexToSeqByte()
        parentContentValue = AccountTrieNodeOffer.decode(parentContentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        contentValue,
      )

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      # check that the offer was received by the second state instance
      let res1 =
        await stateNode2.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == contentValue.toRetrievalValue()
        res1.get().node == contentValue.toRetrievalValue().node

      # check that the parent offer was not received by the second state instance
      let res2 = await stateNode2.stateNetwork.getAccountTrieNode(
        parentContentKey.accountTrieNodeKey
      )
      check:
        not stateNode2.containsId(parentContentId)
        res2.isNone()

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Gossip contract trie nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
      stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

    stateNode1.start()
    stateNode2.start()

    check:
      stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

    for i, testData in testCase:
      if i == 1:
        continue # skip scenario with no parent

      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()

        parentContentKeyBytes =
          testData.recursive_gossip.content_key.hexToSeqByte().ByteList
        parentContentKey = ContentKey.decode(parentContentKeyBytes).get()
        parentContentId = toContentId(parentContentKeyBytes)
        parentContentValueBytes =
          testData.recursive_gossip.content_value_offer.hexToSeqByte()
        parentContentValue = ContractTrieNodeOffer.decode(parentContentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractTrieNodeKey,
        contentValue,
      )

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      # check that the offer was received by the second state instance
      let res1 = await stateNode2.stateNetwork.getContractTrieNode(
        contentKey.contractTrieNodeKey
      )
      check:
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == contentValue.toRetrievalValue()
        res1.get().node == contentValue.toRetrievalValue().node

      # check that the offer parent was not received by the second state instance
      let res2 = await stateNode2.stateNetwork.getContractTrieNode(
        parentContentKey.contractTrieNodeKey
      )
      check:
        not stateNode2.containsId(parentContentId)
        res2.isNone()

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Gossip contract bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let
      testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
      stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

    stateNode1.start()
    stateNode2.start()

    check:
      stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

    for i, testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractCodeKey,
        contentValue,
      )

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      # check that the offer was received by the second state instance
      let res1 =
        await stateNode2.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == contentValue.toRetrievalValue()
        res1.get().code == contentValue.toRetrievalValue().code

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Recursive gossip account trie nodes":
    const file = testVectorDir / "recursive_gossip.yaml"

    let
      testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
      stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

    stateNode1.start()
    stateNode2.start()

    check:
      stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
      stateNode2.portalProtocol().addNode(stateNode1.localNode()) == Added
      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()
      (await stateNode2.portalProtocol().ping(stateNode1.localNode())).isOk()

    for i, testData in testCase:
      if i == 1:
        continue

      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        leafData = testData.recursive_gossip[0]
        contentKeyBytes = leafData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = leafData.content_value.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode1.containsId(contentId)
      check not stateNode2.containsId(contentId)

      # offer the leaf node
      await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        contentValue,
      )

      # wait for recursive gossip to complete
      for node in testData.recursive_gossip:
        let keyBytes = node.content_key.hexToSeqByte().ByteList
        await stateNode2.waitUntilContentAvailable(toContentId(keyBytes))

      # check that all nodes were received by both state instances
      for kv in testData.recursive_gossip:
        let
          expectedKeyBytes = kv.content_key.hexToSeqByte().ByteList
          expectedKey = ContentKey.decode(expectedKeyBytes).get()
          expectedId = toContentId(expectedKeyBytes)
          expectedValue =
            AccountTrieNodeOffer.decode(kv.content_value.hexToSeqByte()).get()
          res1 = await stateNode1.stateNetwork.getAccountTrieNode(
            expectedKey.accountTrieNodeKey
          )
          res2 = await stateNode2.stateNetwork.getAccountTrieNode(
            expectedKey.accountTrieNodeKey
          )
        check:
          stateNode1.containsId(expectedId)
          stateNode2.containsId(expectedId)
          res1.isOk()
          res1.get() == expectedValue.toRetrievalValue()
          res1.get().node == expectedValue.toRetrievalValue().node
          res2.isOk()
          res2.get() == expectedValue.toRetrievalValue()
          res2.get().node == expectedValue.toRetrievalValue().node

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Recursive gossip contract trie nodes":
    const file = testVectorDir / "recursive_gossip.yaml"

    let
      testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
      stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

    stateNode1.start()
    stateNode2.start()

    check:
      stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
      stateNode2.portalProtocol().addNode(stateNode1.localNode()) == Added
      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()
      (await stateNode2.portalProtocol().ping(stateNode1.localNode())).isOk()

    for i, testData in testCase:
      if i != 1:
        continue

      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        leafData = testData.recursive_gossip[0]
        contentKeyBytes = leafData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = leafData.content_value.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode1.containsId(contentId)
      check not stateNode2.containsId(contentId)

      # offer the leaf node
      await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractTrieNodeKey,
        contentValue,
      )

      # wait for recursive gossip to complete
      for node in testData.recursive_gossip:
        let keyBytes = node.content_key.hexToSeqByte().ByteList
        await stateNode2.waitUntilContentAvailable(toContentId(keyBytes))

      # check that all nodes were received by both state instances
      for kv in testData.recursive_gossip:
        let
          expectedKeyBytes = kv.content_key.hexToSeqByte().ByteList
          expectedKey = ContentKey.decode(expectedKeyBytes).get()
          expectedId = toContentId(expectedKeyBytes)
          expectedValue =
            ContractTrieNodeOffer.decode(kv.content_value.hexToSeqByte()).get()
          res1 = await stateNode1.stateNetwork.getContractTrieNode(
            expectedKey.contractTrieNodeKey
          )
          res2 = await stateNode2.stateNetwork.getContractTrieNode(
            expectedKey.contractTrieNodeKey
          )
        check:
          stateNode1.containsId(expectedId)
          stateNode2.containsId(expectedId)
          res1.isOk()
          res1.get() == expectedValue.toRetrievalValue()
          res1.get().node == expectedValue.toRetrievalValue().node
          res2.isOk()
          res2.get() == expectedValue.toRetrievalValue()
          res2.get().node == expectedValue.toRetrievalValue().node

    await stateNode1.stop()
    await stateNode2.stop()
