# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/[byteutils, results],
  testutils/unittests,
  chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ./helpers,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/state/[state_content, state_network],
  ../../database/content_db,
  .././test_helpers,
  ../../eth_data/history_data_json_store

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/"

procSuite "State Network Gossip":
  let rng = newRng()

  asyncTest "Test Gossip of Account Trie Node Offer":
    let
      recursiveGossipSteps = readJsonType(testVectorDir & "recursive_gossip.json", JsonRecursiveGossip).valueOr:
        raiseAssert "Cannot read test vector: " & error
      numOfClients = recursiveGossipSteps.len() - 1

    var clients: seq[StateNetwork]

    for i in 0..numOfClients:
      let
        node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20400 + i))
        sm = StreamManager.new(node)
        proto = StateNetwork.new(node, ContentDB.new("", uint32.high, inMemory = true), sm)
      proto.start()
      clients.add(proto)

    for i in 0..numOfClients-1:
      let
        currentNode = clients[i]
        nextNode = clients[i+1]
      check:
        currentNode.portalProtocol.addNode(nextNode.portalProtocol.localNode) == Added
        (await currentNode.portalProtocol.ping(nextNode.portalProtocol.localNode)).isOk()

    for i in 0..numOfClients-1:
      let
        pair = recursiveGossipSteps[i]
        currentNode = clients[i]
        nextNode = clients[i+1]

        key = ByteList.init(pair.content_key.hexToSeqByte())
        decodedKey = key.decode().valueOr:
          raiseAssert "Cannot decode key"

        nextKey = ByteList.init(recursiveGossipSteps[1].content_key.hexToSeqByte())
        decodedNextKey = nextKey.decode().valueOr:
          raiseAssert "Cannot decode key"

        value = pair.content_value.hexToSeqByte()
        decodedValue = SSZ.decode(value, AccountTrieNodeOffer)
        offerValue = OfferContentValue(contentType: accountTrieNode, accountTrieNode: decodedValue)

        nextValue = recursiveGossipSteps[1].content_value.hexToSeqByte()
        nextDecodedValue = SSZ.decode(nextValue, AccountTrieNodeOffer)
        nextOfferValue = OfferContentValue(contentType: accountTrieNode, accountTrieNode: nextDecodedValue)
        nextRetrievalValue = nextOfferValue.offerContentToRetrievalContent().encode()

      if i == 0:
        await currentNode.portalProtocol.gossipContent(
          Opt.none(NodeId),
          key,
          decodedKey,
          value,
          offerValue
          )

      await sleepAsync(100.milliseconds) #TODO figure out how to get rid of this sleep

      check (await nextNode.getContent(decodedNextKey)) == Opt.some(nextRetrievalValue)

    for i in 0..numOfClients:
      await clients[i].portalProtocol.baseProtocol.closeWait()

  # TODO Add tests for Contract Trie Node Offer & Contract Code Offer
