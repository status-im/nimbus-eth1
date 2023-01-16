# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests, chronos,
  eth/[common/eth_hash, keys, trie/db, trie/hexary],
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  ../../nimbus/[config, db/db_chain, db/state_db],
  ../../nimbus/common/[chain_config, genesis],
  ../network/wire/[portal_protocol, portal_stream],
  ../network/state/[state_content, state_network],
  ../content_db,
  ./test_helpers

proc genesisToTrie(filePath: string): HexaryTrie =
  # TODO: Doing our best here with API that exists, to be improved.
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  let sdb  = newStateDB(newMemoryDB(), false)
  let map  = toForkTransitionTable(cn.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.toBlockNumber, cn.genesis.timestamp))
  discard toGenesisHeader(cn.genesis, sdb, fork)

  sdb.getTrie

procSuite "State Content Network":
  let rng = newRng()
  asyncTest "Test Share Full State":
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")

      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      sm2 = StreamManager.new(node2)

      proto1 = StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 = StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)

    check proto2.portalProtocol.addNode(node1.localNode) == Added

    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr k[0], sizeof(nodeHash.data))

      let
        # TODO: add stateRoot, and path eventually
        accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
        contentKey = ContentKey(
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)
        contentId = toContentId(contentKey)

      discard proto1.contentDB.put(contentId, v, proto1.portalProtocol.localNode.id)

    for key in keys:
      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr key[0], sizeof(nodeHash.data))

      let
        accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
        contentKey = ContentKey(
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)
        contentId = toContentId(contentKey)

      # Note: GetContent and thus the lookup here is not really needed, as we
      # only have to request data to one node.
      let foundContent = await proto2.getContent(contentKey)

      check:
        foundContent.isSome()

      let hash = keccakHash(foundContent.get())
      check hash.data == key

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Find content in the network via content lookup":
    # TODO: Improve this test so it actually need to go through several
    # findNodes request, to properly test the lookup call.
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      sm2 = StreamManager.new(node2)
      node3 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20304))
      sm3 = StreamManager.new(node3)

      proto1 = StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 = StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)
      proto3 = StateNetwork.new(node3, ContentDB.new("", uint32.high, inMemory = true), sm3)

    # Node1 knows about Node2, and Node2 knows about Node3 which hold all content
    check proto1.portalProtocol.addNode(node2.localNode) == Added
    check proto2.portalProtocol.addNode(node3.localNode) == Added

    check (await proto2.portalProtocol.ping(node3.localNode)).isOk()

    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr k[0], sizeof(nodeHash.data))

      let
        accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
        contentKey = ContentKey(
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)
        contentId = toContentId(contentKey)

      discard proto2.contentDB.put(contentId, v, proto2.portalProtocol.localNode.id)
      # Not needed right now as 1 node is enough considering node 1 is connected
      # to both.
      discard proto3.contentDB.put(contentId, v, proto3.portalProtocol.localNode.id)

    # Get first key
    var nodeHash: NodeHash
    let firstKey = keys[0]
    copyMem(nodeHash.data.addr, unsafeAddr firstKey[0], sizeof(nodeHash.data))

    let
      accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
      contentKey = ContentKey(
        contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)

    let foundContent = await proto1.getContent(contentKey)

    check:
      foundContent.isSome()

    let hash = keccakHash(foundContent.get())

    check hash.data == firstKey

    await node1.closeWait()
    await node2.closeWait()
    await node3.closeWait()

  asyncTest "Find other nodes in state network with correct custom distance":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      sm2 = StreamManager.new(node2)

      proto1 = StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 = StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)

    check (await node1.ping(node2.localNode)).isOk()
    check (await node2.ping(node1.localNode)).isOk()

    proto2.portalProtocol.seedTable()

    let distance = proto1.portalProtocol.routingTable.logDistance(
      node1.localNode.id, node2.localNode.id)

    let nodes = await proto1.portalProtocol.findNodes(
        proto2.portalProtocol.localNode, @[distance])

    # TODO: This gives an error because of the custom distances issues that
    # need to be resolved first.
    skip()
    # check:
    #   nodes.isOk()
    #   nodes.get().len() == 1

    await node1.closeWait()
    await node2.closeWait()
