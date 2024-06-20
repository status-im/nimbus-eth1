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
  ../../network/state/
    [state_content, state_network, state_gossip, state_endpoints, state_utils],
  ../../database/content_db,
  ./state_test_helpers

procSuite "State Endpoints":
  const STATE_NODE1_PORT = 20602
  const STATE_NODE2_PORT = 20603

  let rng = newRng()

  asyncTest "Gossip then query getBalance and getTransactionCount":
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

      let
        address =
          if i == 0:
            EthAddress.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
          elif i == 2:
            EthAddress.fromHex("0x1584a2c066b7a455dbd6ae2807a7334e83c35fa5")
          else:
            raiseAssert("Invalid test case")
        expectedAccount = contentValue.proof.toAccount().get()

      block:
        # check stateNode1
        let
          balanceRes =
            await stateNode1.stateNetwork.getBalance(contentValue.blockHash, address)
          nonceRes = await stateNode1.stateNetwork.getTransactionCount(
            contentValue.blockHash, address
          )

        check:
          balanceRes.isOk()
          balanceRes.get() == expectedAccount.balance
          nonceRes.isOk()
          nonceRes.get() == expectedAccount.nonce

      block:
        # check stateNode2
        let
          balanceRes =
            await stateNode2.stateNetwork.getBalance(contentValue.blockHash, address)
          nonceRes = await stateNode2.stateNetwork.getTransactionCount(
            contentValue.blockHash, address
          )

        check:
          balanceRes.isOk()
          balanceRes.get() == expectedAccount.balance
          nonceRes.isOk()
          nonceRes.get() == expectedAccount.nonce

      block:
        # test non-existant account
        let
          badAddress = EthAddress.fromHex("0xbadaaa39b223fe8d0a0e5c4f27ead9083c756cc2")
          balanceRes =
            await stateNode2.stateNetwork.getBalance(contentValue.blockHash, badAddress)
          nonceRes = await stateNode2.stateNetwork.getTransactionCount(
            contentValue.blockHash, badAddress
          )

        check:
          balanceRes.isNone()
          nonceRes.isNone()

    await stateNode1.stop()
    await stateNode2.stop()

  asyncTest "Gossip then query getStorageAt and getCode":
    const
      file = testVectorDir / "recursive_gossip.yaml"
      bytecodeFile = testVectorDir / "contract_bytecode.yaml"

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

    block:
      # seed the account data
      let
        testData = testCase[0]
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

      # offer the leaf node
      await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        contentValue,
      )

    block:
      # seed the storage data
      let
        testData = testCase[1]
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

      let
        address = EthAddress.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        slot = 2.u256
        badSlot = 3.u256
        expectedSlot = contentValue.storageProof.toSlot().get()

        slotRes = await stateNode2.stateNetwork.getStorageAt(
          contentValue.blockHash, address, slot
        )
        badSlotRes = await stateNode2.stateNetwork.getStorageAt(
          contentValue.blockHash, address, badSlot
        )

      check:
        slotRes.isOk()
        slotRes.get() == expectedSlot
        badSlotRes.isNone()

    block:
      # seed the contract bytecode
      let
        testCase = YamlContractBytecodeKVs.loadFromYaml(bytecodeFile).valueOr:
          raiseAssert "Cannot read test vector: " & error
        testData = testCase[0]
        stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())
        contentKeyBytes = testData.content_key.hexToSeqByte().ByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)
      stateNode2.mockBlockHashToStateRoot(contentValue.blockHash, stateRoot)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractCodeKey,
        contentValue,
      )

      # wait for gossip to complete
      await stateNode2.waitUntilContentAvailable(contentId)

      let
        address = EthAddress.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        badAddress = EthAddress.fromHex("0xbadaaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        expectedCode = contentValue.code

        codeRes = await stateNode2.stateNetwork.getCode(contentValue.blockHash, address)
        badCodeRes =
          await stateNode2.stateNetwork.getCode(contentValue.blockHash, badAddress)

      check:
        codeRes.isOk()
        codeRes.get() == expectedCode
        badCodeRes.isNone()

    await stateNode1.stop()
    await stateNode2.stop()
