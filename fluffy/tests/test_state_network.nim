# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  testutils/unittests,
  eth/[keys, trie/db, trie/hexary, ssz/ssz_serialization],
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  ../../nimbus/[genesis, chain_config, config, db/db_chain],
  ../network/wire/portal_protocol,
  ../network/state/[state_content, state_network],
  ../content_db,
  ./test_helpers

proc genesisToTrie(filePath: string): HexaryTrie =
  # TODO: Doing our best here with API that exists, to be improved.
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  var chainDB = newBaseChainDB(
    newMemoryDb(),
    pruneTrie = false,
    CustomNet,
    cn
  )
  # TODO: this actually also creates a HexaryTrie and AccountStateDB, which we
  # could skip
  let header = toBlock(cn.genesis, chainDB)

  # Trie exists already in flat db, but need to provide the root
  initHexaryTrie(chainDB.db, header.stateRoot, chainDB.pruneTrie)

procSuite "State Content Network":
  let rng = newRng()
  asyncTest "Test Share Full State":
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")

      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = StateNetwork.new(node1, ContentDB.new("", inMemory = true))
      proto2 = StateNetwork.new(node2, ContentDB.new("", inMemory = true))

    check proto2.portalProtocol.addNode(node1.localNode) == Added

    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr k[0], sizeof(nodeHash.data))

      let
        contentKey = ContentKey(
          networkId: 0'u16,
          contentType: state_content.ContentType.Account,
          nodeHash: nodeHash)
        contentId = toContentId(contentKey)

      proto1.contentDB.put(contentId, v)

    for key in keys:
      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr key[0], sizeof(nodeHash.data))

      let
        contentKey = ContentKey(
          networkId: 0'u16,
          contentType: state_content.ContentType.Account,
          nodeHash: nodeHash)

      # Note: GetContent and thus the lookup here is not really needed, as we
      # only have to request data to one node.
      let foundContent = await proto2.getContent(contentKey)

      check:
        foundContent.isSome()

      let hash = hexary.keccak(foundContent.get())
      check hash.data == key

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Find content in the network via content lookup":
    # TODO: Improve this test so it actually need to go through several
    # findNode request, to properly test the lookup call.
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      node3 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20304))


      proto1 = StateNetwork.new(node1, ContentDB.new("", inMemory = true))
      proto2 = StateNetwork.new(node2, ContentDB.new("", inMemory = true))
      proto3 = StateNetwork.new(node3, ContentDB.new("", inMemory = true))


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
        contentKey = ContentKey(
          networkId: 0'u16,
          contentType: state_content.ContentType.Account,
          nodeHash: nodeHash)
        contentId = toContentId(contentKey)

      proto2.contentDB.put(contentId, v)
      # Not needed right now as 1 node is enough considering node 1 is connected
      # to both.
      proto3.contentDB.put(contentId, v)

    # Get first key
    var nodeHash: NodeHash
    let firstKey = keys[0]
    copyMem(nodeHash.data.addr, unsafeAddr firstKey[0], sizeof(nodeHash.data))

    let contentKey = ContentKey(
      networkId: 0'u16,
      contentType: state_content.ContentType.Account,
      nodeHash: nodeHash)

    let foundContent = await proto1.getContent(contentKey)

    check:
      foundContent.isSome()

    let hash = hexary.keccak(foundContent.get())

    check hash.data == firstKey

    await node1.closeWait()
    await node2.closeWait()
    await node3.closeWait()

  asyncTest "Find other nodes in state network with correct custom distance":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))


      proto1 = StateNetwork.new(node1, ContentDB.new("", inMemory = true))
      proto2 = StateNetwork.new(node2, ContentDB.new("", inMemory = true))

    check (await node1.ping(node2.localNode)).isOk()
    check (await node2.ping(node1.localNode)).isOk()

    proto2.portalProtocol.seedTable()

    let distance = proto1.portalProtocol.routingTable.logDistance(
      node1.localNode.id, node2.localNode.id)

    let nodes = await proto1.portalProtocol.findNode(
        proto2.portalProtocol.localNode, List[uint16, 256](@[distance]))

    check:
      nodes.isOk()
      nodes.get().total == 1'u8
      nodes.get().enrs.len() == 1

    await node1.closeWait()
    await node2.closeWait()
