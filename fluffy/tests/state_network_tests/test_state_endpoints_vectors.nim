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
  eth/common/[addresses, headers_rlp],
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

    for i, testData in testCase:
      if i != 0 and i != 3:
        # only using the leaf nodes from the test data
        continue

      let
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        leafData = testData
        contentKeyBytes = leafData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentValueBytes = leafData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      # offer the leaf node
      let rootKeyBytes = await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        contentValue,
      )

      await stateNode1.waitUntilContentAvailable(toContentId(rootKeyBytes))
      await stateNode2.waitUntilContentAvailable(toContentId(rootKeyBytes))

      let
        address =
          if i == 0:
            addresses.Address.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
          elif i == 3:
            addresses.Address.fromHex("0x1584a2c066b7a455dbd6ae2807a7334e83c35fa5")
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
        # check stateNode1 by state root
        let
          balanceRes =
            await stateNode1.stateNetwork.getBalanceByStateRoot(stateRoot, address)
          nonceRes = await stateNode1.stateNetwork.getTransactionCountByStateRoot(
            stateRoot, address
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
          badAddress =
            addresses.Address.fromHex("0xbadaaa39b223fe8d0a0e5c4f27ead9083c756cc2")
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
      accountTrieFile = testVectorDir / "account_trie_node.yaml"
      contractTrieFile = testVectorDir / "contract_storage_trie_node.yaml"
      bytecodeFile = testVectorDir / "contract_bytecode.yaml"

    let
      accountTrieTestCase = YamlTrieNodeKVs.loadFromYaml(accountTrieFile).valueOr:
        raiseAssert "Cannot read test vector: " & error
      contractTrieTestCase = YamlTrieNodeKVs.loadFromYaml(contractTrieFile).valueOr:
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
        testData = accountTrieTestCase[0]
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        leafData = testData
        contentKeyBytes = leafData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentValueBytes = leafData.content_value_offer.hexToSeqByte()
        contentValue = AccountTrieNodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      # offer the leaf node
      let rootKeyBytes = await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.accountTrieNodeKey,
        contentValue,
      )

      # wait for gossip to complete
      await stateNode2.waitUntilContentAvailable(toContentId(rootKeyBytes))

    block:
      # seed the storage data
      let
        testData = contractTrieTestCase[0]
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        leafData = testData
        contentKeyBytes = leafData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentValueBytes = leafData.content_value_offer.hexToSeqByte()
        contentValue = ContractTrieNodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      # offer the leaf node
      let storageRootKeyBytes = await stateNode1.portalProtocol.recursiveGossipOffer(
        Opt.none(NodeId),
        contentKeyBytes,
        contentValueBytes,
        contentKey.contractTrieNodeKey,
        contentValue,
      )

      # wait for gossip to complete
      await stateNode2.waitUntilContentAvailable(toContentId(storageRootKeyBytes))

      let
        address =
          addresses.Address.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        slot = 2.u256
        badSlot = 3.u256
        expectedSlot = contentValue.storageProof.toSlot().get()

        slotRes = await stateNode2.stateNetwork.getStorageAt(
          contentValue.blockHash, address, slot
        )
        badSlotRes = await stateNode2.stateNetwork.getStorageAt(
          contentValue.blockHash, address, badSlot
        )
        slotByStateRootRes = await stateNode2.stateNetwork.getStorageAtByStateRoot(
          stateRoot, address, slot
        )

      check:
        slotRes.isOk()
        slotRes.get() == expectedSlot
        badSlotRes.isNone()
        slotByStateRootRes.isOk()
        slotByStateRootRes.get() == expectedSlot

    block:
      # seed the contract bytecode
      let
        testCase = YamlContractBytecodeKVs.loadFromYaml(bytecodeFile).valueOr:
          raiseAssert "Cannot read test vector: " & error
        testData = testCase[0]
        stateRoot = rlp.decode(testData.block_header.hexToSeqByte(), Header).stateRoot
        contentKeyBytes = testData.content_key.hexToSeqByte().ContentKeyByteList
        contentKey = ContentKey.decode(contentKeyBytes).get()
        contentId = toContentId(contentKeyBytes)
        contentValueBytes = testData.content_value_offer.hexToSeqByte()
        contentValue = ContractCodeOffer.decode(contentValueBytes).get()

      # set valid state root
      stateNode1.mockStateRootLookup(contentValue.blockHash, stateRoot)
      stateNode2.mockStateRootLookup(contentValue.blockHash, stateRoot)

      await stateNode1.portalProtocol.gossipOffer(
        Opt.none(NodeId), contentKeyBytes, contentValueBytes
      )

      # wait for gossip to complete
      await stateNode2.waitUntilContentAvailable(contentId)

      let
        address =
          addresses.Address.fromHex("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        badAddress =
          addresses.Address.fromHex("0xbadaaa39b223fe8d0a0e5c4f27ead9083c756cc2")
        expectedCode = contentValue.code

        codeRes = await stateNode2.stateNetwork.getCode(contentValue.blockHash, address)
        badCodeRes =
          await stateNode2.stateNetwork.getCode(contentValue.blockHash, badAddress)
        codeByStateRootRes =
          await stateNode2.stateNetwork.getCodeByStateRoot(stateRoot, address)

      check:
        codeRes.isOk()
        codeRes.get() == expectedCode
        badCodeRes.isNone()
        codeByStateRootRes.isOk()
        codeByStateRootRes.get() == expectedCode

    await stateNode1.stop()
    await stateNode2.stop()
