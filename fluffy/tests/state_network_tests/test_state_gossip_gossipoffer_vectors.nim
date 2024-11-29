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
  eth/common/headers_rlp,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
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
      if i != 0 and i != 3:
        continue # skip scenarios with no parent

      let
        parentTestData = testCase[i + 1]
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()

        parentContentKeyBytes =
          parentTestData.content_key.hexToSeqByte().ContentKeyByteList
        parentContentKey = ContentKey.decode(parentContentKeyBytes).get()
        parentContentId = toContentId(parentContentKeyBytes)
        parentContentValueBytes = parentTestData.content_value_offer.hexToSeqByte()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId), contentKeyBytes, contentValueBytes
      )

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      # check that the offer was received by the second state instance
      let res1 =
        await stateNode2.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == contentValue.toRetrieval()
        res1.get().node == contentValue.toRetrieval().node

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
      if i != 0:
        continue # skip scenarios with no parent

      let
        parentTestData = testCase[i + 1]
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()

        parentContentKeyBytes =
          parentTestData.content_key.hexToSeqByte().ContentKeyByteList
        parentContentKey = ContentKey.decode(parentContentKeyBytes).get()
        parentContentId = toContentId(parentContentKeyBytes)
        parentContentValueBytes = parentTestData.content_value_offer.hexToSeqByte()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId), contentKeyBytes, contentValueBytes
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
        res1.get() == contentValue.toRetrieval()
        res1.get().node == contentValue.toRetrieval().node

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
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId), contentKeyBytes, contentValueBytes
      )

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      # check that the offer was received by the second state instance
      let res1 =
        await stateNode2.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == contentValue.toRetrieval()
        res1.get().code == contentValue.toRetrieval().code

    await stateNode1.stop()
    await stateNode2.stop()
