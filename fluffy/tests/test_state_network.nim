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

      proto1 = StateNetwork.new(node1, ContentStorage(trie: trie))
      proto2 = StateNetwork.new(node2, ContentStorage(trie: trie))

    check proto2.portalProtocol.addNode(node1.localNode) == Added

    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

    for key in keys:
      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr key[0], sizeof(nodeHash.data))

      let
        contentKey = ContentKey(
          networkId: 0'u16,
          contentType: state_content.ContentType.Account,
          nodeHash: nodeHash)

      let foundContent = await proto2.getContent(contentKey)

      check:
        foundContent.isSome()

      let hash = hexary.keccak(foundContent.get())
      check hash.data == key

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Find content in the network via content lookup":
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      node3 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20304))


      proto1 = StateNetwork.new(node1, ContentStorage(trie: trie))
      proto2 = StateNetwork.new(node2, ContentStorage(trie: trie))
      proto3 = StateNetwork.new(node3, ContentStorage(trie: trie))


    # Node1 knows about Node2, and Node2 knows about Node3 which hold all content
    check proto1.portalProtocol.addNode(node2.localNode) == Added
    check proto2.portalProtocol.addNode(node3.localNode) == Added

    check (await proto2.portalProtocol.ping(node3.localNode)).isOk()

    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

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
