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
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/state/[state_content, state_network],
  ../../database/content_db,
  ./state_test_helpers

procSuite "State Network - Get Content":
  const STATE_NODE1_PORT = 20402
  const STATE_NODE2_PORT = 20403

  let rng = newRng()

  # Single state instance tests

  asyncTest "Single state instance - Get existing account trie node":
    const file = testVectorDir / "account_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = AccountTrieNodeRetrieval.decode(contentValueBytes).get()

      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )

      let res =
        await stateNode1.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        res.isOk()
        res.get() == expectedContentValue
        res.get().node == expectedContentValue.node

    await stateNode1.stop()

  asyncTest "Single state instance - Get missing account trie node":
    const file = testVectorDir / "account_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()

      let res =
        await stateNode1.stateNetwork.getAccountTrieNode(contentKey.accountTrieNodeKey)
      check:
        res.isNone()

    await stateNode1.stop()

  asyncTest "Single state instance - Get existing contract trie node":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = ContractTrieNodeRetrieval.decode(contentValueBytes).get()

      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )

      let res = await stateNode1.stateNetwork.getContractTrieNode(
        contentKey.contractTrieNodeKey
      )
      check:
        res.isOk()
        res.get() == expectedContentValue
        res.get().node == expectedContentValue.node

    await stateNode1.stop()

  asyncTest "Single state instance - Get missing contract trie node":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let
      testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()

      let res = await stateNode1.stateNetwork.getContractTrieNode(
        contentKey.contractTrieNodeKey
      )
      check:
        res.isNone()

    await stateNode1.stop()

  asyncTest "Single state instance - Get existing contract bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let
      testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = ContractCodeRetrieval.decode(contentValueBytes).get()

      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )

      let res =
        await stateNode1.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        res.isOk()
        res.get() == expectedContentValue
        res.get().code == expectedContentValue.code

    await stateNode1.stop()

  asyncTest "Single state instance - Get missing contract bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let
      testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      stateNode1 = newStateNode(rng, STATE_NODE1_PORT)

    stateNode1.start()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()

      let res =
        await stateNode1.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        res.isNone()

    await stateNode1.stop()

  # Two state instances tests

  asyncTest "Two state instances - Get existing account trie node":
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
      stateNode2.portalProtocol().addNode(stateNode1.localNode()) == Added

      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()
      (await stateNode2.portalProtocol().ping(stateNode1.localNode())).isOk()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = AccountTrieNodeRetrieval.decode(contentValueBytes).get()

      # only store the content in the first state instance
      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )
      check:
        stateNode1.containsId(contentId)
        not stateNode2.containsId(contentId)

      let
        res1 = await stateNode1.stateNetwork.getAccountTrieNode(
          contentKey.accountTrieNodeKey
        )
        res2 = await stateNode2.stateNetwork.getAccountTrieNode(
          contentKey.accountTrieNodeKey
        )
      check:
        stateNode1.containsId(contentId)
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == expectedContentValue
        res1.get().node == expectedContentValue.node
        res2.isOk()
        res2.get() == expectedContentValue
        res2.get().node == expectedContentValue.node

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Two state instances - Get existing contract trie node":
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
      stateNode2.portalProtocol().addNode(stateNode1.localNode()) == Added

      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()
      (await stateNode2.portalProtocol().ping(stateNode1.localNode())).isOk()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = ContractTrieNodeRetrieval.decode(contentValueBytes).get()

      # only store the content in the first state instance
      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )
      check:
        stateNode1.containsId(contentId)
        not stateNode2.containsId(contentId)

      let
        res1 = await stateNode1.stateNetwork.getContractTrieNode(
          contentKey.contractTrieNodeKey
        )
        res2 = await stateNode2.stateNetwork.getContractTrieNode(
          contentKey.contractTrieNodeKey
        )
      check:
        stateNode1.containsId(contentId)
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == expectedContentValue
        res1.get().node == expectedContentValue.node
        res2.isOk()
        res2.get() == expectedContentValue
        res2.get().node == expectedContentValue.node

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Two state instances - Get existing contract bytecode":
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
      stateNode2.portalProtocol().addNode(stateNode1.localNode()) == Added

      (await stateNode1.portalProtocol().ping(stateNode2.localNode())).isOk()
      (await stateNode2.portalProtocol().ping(stateNode1.localNode())).isOk()

    for testData in testCase:
      let
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_retrieval.hexToSeqByte()
        expectedContentValue = ContractCodeRetrieval.decode(contentValueBytes).get()

      # only store the content in the first state instance
      stateNode1.portalProtocol().storeContent(
        contentKeyBytes, contentId, contentValueBytes
      )
      check:
        stateNode1.containsId(contentId)
        not stateNode2.containsId(contentId)

      let
        res1 = await stateNode1.stateNetwork.getContractCode(contentKey.contractCodeKey)
        res2 = await stateNode2.stateNetwork.getContractCode(contentKey.contractCodeKey)
      check:
        stateNode1.containsId(contentId)
        stateNode2.containsId(contentId)
        res1.isOk()
        res1.get() == expectedContentValue
        res1.get().code == expectedContentValue.code
        res2.isOk()
        res2.get() == expectedContentValue
        res2.get().code == expectedContentValue.code

    await stateNode1.stop()
    await stateNode2.stop()
