# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sugar, sequtils],
  stew/[byteutils, results],
  testutils/unittests,
  chronos,
  eth/common/eth_hash,
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

  # asyncTest "Test Gossip of Contract Code":
  #   const encodedKey = ByteList.init("20240000006225fcc63b22b80301d9f2582014e450e91f9b329b7cc87ad16894722fff529600050000008679e8ed".hexToSeqByte())
  #   let
  #     node1 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20302))
  #     sm1 = StreamManager.new(node1)
  #     node2 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20303))
  #     sm2 = StreamManager.new(node2)

  #     proto1 = StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
  #     proto2 = StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)

  #     blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
  #       raiseAssert "Cannot read test vector: " & error
  #     recursiveGossipSteps = readJsonType(testVectorDir & "recursive_gossip.json", JsonRecursiveGossip).valueOr:
  #       raiseAssert "Cannot read test vector: " & error

  #   check proto2.portalProtocol.addNode(node1.localNode) == Added
  #   check (await node2.ping(node1.localNode)).isOk()

  #   let
  #     pair = recursiveGossipSteps[0]
  #     key = ByteList.init(pair.content_key.hexToSeqByte())
  #     decodedKey = key.decode().valueOr:
  #       raiseAssert "Cannot decode key"
  #     value = pair.content_value.hexToSeqByte()

  #   await proto1.portalProtocol.gossipContent(Opt.none(NodeId), ContentKeysList.init(@[key]), @[value], neighborhoodGossipDiscardPeers)
  #   let gossipedValue = await proto2.getContent(decodedKey)

  #   check gossipedValue.isSome()
  #   check gossipedValue.get() == value


  #   await node1.closeWait()
  #   await node2.closeWait()

  asyncTest "Test gossipContent method":
    let
      node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20302))
      sm = StreamManager.new(node)
      proto = StateNetwork.new(node, ContentDB.new("", uint32.high, inMemory = true), sm)
      srcNodeId = proto.portalProtocol.localNode.id

      blockContent = readJsonType(testVectorDir & "block.json", JsonBlock).valueOr:
        raiseAssert "Cannot read test vector: " & error
      recursiveGossipSteps = readJsonType(testVectorDir & "recursive_gossip.json", JsonRecursiveGossip).valueOr:
        raiseAssert "Cannot read test vector: " & error

    for i, pair in recursiveGossipSteps[0..^2]:
      let
        key = ByteList.init(pair.content_key.hexToSeqByte())
        nextKey = ByteList.init(recursiveGossipSteps[i + 1].content_key.hexToSeqByte())
        value = pair.content_value.hexToSeqByte()
        nextValue = recursiveGossipSteps[i + 1].content_value.hexToSeqByte()

      proc gossipProc(p: PortalProtocol, nid: Opt[NodeId], keys: ContentKeysList, values: seq[seq[byte]]): Future[void] {.async} =
        check (distinctBase keys)[0] == nextKey
        check values[0] == nextValue
        return

      await gossipContent(proto.portalProtocol, Opt.some(srcNodeId), ContentKeysList.init(@[key]), @[value], gossipProc)
