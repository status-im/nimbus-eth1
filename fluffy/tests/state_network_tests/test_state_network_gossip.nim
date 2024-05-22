# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  chronos,
  testutils/unittests,
  stew/[byteutils, results],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/history/[history_content, history_network],
  ../../network/state/[state_content, state_network, state_gossip],
  ../../database/content_db,
  .././test_helpers,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

procSuite "State Network Gossip":
  let rng = newRng()

  asyncTest "Test Gossip of Account Trie Node Offer":
    const file = testVectorDir / "recursive_gossip.yaml"

    type YamlRecursiveGossipKV = object
      content_key: string
      content_value: string

    type YamlRecursiveGossipData = object
      state_root: string
      recursive_gossip: seq[YamlRecursiveGossipKV]

    type YamlRecursiveGossipKVs = seq[YamlRecursiveGossipData]

    let
      testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error
      recursiveGossipSteps = testCase[0].recursive_gossip
      numOfClients = recursiveGossipSteps.len() - 1

    var clients: seq[StateNetwork]

    for i in 0 .. numOfClients:
      let
        node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20400 + i))
        db = ContentDB.new("", uint32.high, inMemory = true)
        sm = StreamManager.new(node)
        hn = HistoryNetwork.new(node, db, sm, FinishedAccumulator())
        proto = StateNetwork.new(node, db, sm, historyNetwork = Opt.some(hn))
      proto.start()
      clients.add(proto)

    for i in 0 .. numOfClients - 1:
      let
        currentNode = clients[i]
        nextNode = clients[i + 1]

      check:
        currentNode.portalProtocol.addNode(nextNode.portalProtocol.localNode) == Added
        (await currentNode.portalProtocol.ping(nextNode.portalProtocol.localNode)).isOk()

      let
        blockHeader = BlockHeader(
          stateRoot: Hash256.fromHex(
            "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61"
          )
        )
        headerRlp = rlp.encode(blockHeader)
        blockHeaderWithProof = BlockHeaderWithProof(
          header: ByteList.init(headerRlp), proof: BlockHeaderProof.init()
        )
        value = recursiveGossipSteps[0].content_value.hexToSeqByte()
        decodedValue = AccountTrieNodeOffer.decode(value).get()
        contentKey = history_content.ContentKey
          .init(history_content.ContentType.blockHeader, decodedValue.blockHash)
          .encode()
        contentId = history_content.toContentId(contentKey)

      clients[i].contentDB.put(contentId, SSZ.encode(blockHeaderWithProof))

    for i in 0 .. numOfClients - 1:
      let
        pair = recursiveGossipSteps[i]
        currentNode = clients[i]
        nextNode = clients[i + 1]

        key = ByteList.init(pair.content_key.hexToSeqByte())
        decodedKey = state_content.ContentKey.decode(key).valueOr:
          raiseAssert "Cannot decode key"

        nextKey = ByteList.init(recursiveGossipSteps[1].content_key.hexToSeqByte())
        decodedNextKey = state_content.ContentKey.decode(nextKey).valueOr:
          raiseAssert "Cannot decode key"

        value = pair.content_value.hexToSeqByte()
        decodedValue = AccountTrieNodeOffer.decode(value).get()
        nextValue = recursiveGossipSteps[1].content_value.hexToSeqByte()
        nextDecodedValue = AccountTrieNodeOffer.decode(nextValue).get()
        nextRetrievalValue = nextDecodedValue.toRetrievalValue()

      if i == 0:
        await currentNode.portalProtocol.gossipOffer(
          Opt.none(NodeId), decodedKey.accountTrieNodeKey, decodedValue
        )

      await sleepAsync(100.milliseconds) #TODO figure out how to get rid of this sleep

      check (await nextNode.getAccountTrieNode(decodedNextKey.accountTrieNodeKey)) ==
        Opt.some(nextRetrievalValue)

    for i in 0 .. numOfClients:
      await clients[i].portalProtocol.baseProtocol.closeWait()

  # TODO Add tests for Contract Trie Node Offer & Contract Code Offer
