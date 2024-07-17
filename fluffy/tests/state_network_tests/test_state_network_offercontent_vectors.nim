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
  ../../network/state/[state_content, state_network],
  ../../database/content_db,
  ./state_test_helpers

procSuite "State Network - Offer Content":
  const
    STATE_NODE1_PORT = 20502
    STATE_NODE2_PORT = 20503

  let rng = newRng()

  # Single state instance tests

  asyncTest "Single state instance - Offer account trie nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

      stateNode1.start()

      # no state root yet
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.accountTrieNodeKey,
          AccountTrieNodeOffer,
        )
      ).isErr()

      # set bad state root
      let badStateRoot = KeccakHash.fromBytes(
        "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
      )
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, badStateRoot)
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.accountTrieNodeKey,
          AccountTrieNodeOffer,
        )
      ).isErr()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode1.containsId(contentId)

      let processRes = await stateNode1.stateNetwork.processOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        AccountTrieNodeOffer,
      )
      check processRes.isOk()

      let getRes =
        await stateNode1.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        stateNode1.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().node == contentValue.toRetrievalValue().node

      await stateNode1.stop()

  asyncTest "Single state instance - Offer contract trie nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

      stateNode1.start()

      # no state root yet
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.contractTrieNodeKey,
          ContractTrieNodeOffer,
        )
      ).isErr()

      # set bad state root
      let badStateRoot = KeccakHash.fromBytes(
        "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
      )
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, badStateRoot)
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.contractTrieNodeKey,
          ContractTrieNodeOffer,
        )
      ).isErr()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode1.containsId(contentId)

      let processRes = await stateNode1.stateNetwork.processOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractTrieNodeKey,
        ContractTrieNodeOffer,
      )
      check processRes.isOk()

      let getRes = await stateNode1.stateNetwork.getContractTrieNode(
        contentKey.contractTrieNodeKey
      )
      check:
        stateNode1.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().node == contentValue.toRetrievalValue().node

      await stateNode1.stop()

  asyncTest "Single state instance - Offer contract bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

      stateNode1.start()

      # no state root yet
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.contractCodeKey,
          ContractCodeOffer,
        )
      ).isErr()

      # set bad state root
      let badStateRoot = KeccakHash.fromBytes(
        "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
      )
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, badStateRoot)
      check (
        await stateNode1.stateNetwork.processOffer(
          Opt.none(NodeId),
          contentKeyBytes,
          contentValueBytes,
          contentKey.contractCodeKey,
          ContractCodeOffer,
        )
      ).isErr()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode1.containsId(contentId)

      let processRes = await stateNode1.stateNetwork.processOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractCodeKey,
        ContractCodeOffer,
      )
      check processRes.isOk()

      let getRes =
        await stateNode1.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        stateNode1.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().code == contentValue.toRetrievalValue().code

      await stateNode1.stop()

  # Two state instances tests - State node 1 offers content to state node 2

  asyncTest "Two state instances - Offer account trie nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()
        contentKV = ContentKV(contentKey: contentKeyBytes, content: contentValueBytes)
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
        stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

      stateNode1.start()
      stateNode2.start()

      check:
        stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
        (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      let offerResult =
        await stateNode1.portalProtocol.offer(stateNode2.localNode(), @[contentKV])
      check offerResult.isOk()

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      let getRes =
        await stateNode2.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        stateNode2.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().node == contentValue.toRetrievalValue().node

      await stateNode1.stop()
      await stateNode2.stop()

  asyncTest "Two state instances - Offer contract trie nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()
        contentKV = ContentKV(contentKey: contentKeyBytes, content: contentValueBytes)
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
        stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

      stateNode1.start()
      stateNode2.start()

      check:
        stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
        (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      let offerResult =
        await stateNode1.portalProtocol.offer(stateNode2.localNode(), @[contentKV])
      check offerResult.isOk()

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      let getRes = await stateNode2.stateNetwork.getContractTrieNode(
        contentKey.contractTrieNodeKey
      )
      check:
        stateNode2.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().node == contentValue.toRetrievalValue().node

      await stateNode1.stop()
      await stateNode2.stop()

  asyncTest "Two state instances - Offer contract bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()
        contentKV = ContentKV(contentKey: contentKeyBytes, content: contentValueBytes)
        stateNode1 = newStateNode(rng, STATE_NODE1_PORT)
        stateNode2 = newStateNode(rng, STATE_NODE2_PORT)

      stateNode1.start()
      stateNode2.start()

      check:
        stateNode1.portalProtocol().addNode(stateNode2.localNode()) == Added
        (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      check not stateNode2.containsId(contentId)

      let offerResult =
        await stateNode1.portalProtocol.offer(stateNode2.localNode(), @[contentKV])
      check offerResult.isOk()

      # wait for offer to be processed by state node 2
      await stateNode2.waitUntilContentAvailable(contentId)

      let getRes =
        await stateNode2.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        stateNode2.containsId(contentId)
        getRes.isOk()
        getRes.get() == contentValue.toRetrievalValue()
        getRes.get().code == contentValue.toRetrievalValue().code

      await stateNode1.stop()
      await stateNode2.stop()
