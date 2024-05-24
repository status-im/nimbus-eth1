# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  nimcrypto/hash,
  testutils/unittests,
  chronos,
  eth/keys,
  eth/trie,
  eth/common/[eth_types, eth_hash],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/state/[state_content, state_network],
  ../../database/content_db,
  ../test_helpers,
  ./state_test_helpers

procSuite "State Network":
  let rng = newRng()

  asyncTest "Test Share Full State":
    let
      accounts =
        getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
      (trie, _) = accounts.toState()
      node1 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20312))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20313))
      sm2 = StreamManager.new(node2)
      proto1 =
        StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 =
        StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)

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
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey
        )
        contentId = toContentId(contentKey.encode())
        value = AccountTrieNodeRetrieval(node: TrieNode.init(v))

      discard proto1.contentDB.put(
        contentId, value.encode(), proto1.portalProtocol.localNode.id
      )

    for key in keys:
      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr key[0], sizeof(nodeHash.data))

      let
        accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
        contentKey = ContentKey(
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey
        )
        contentId = toContentId(contentKey.encode())

      # Note: GetContent and thus the lookup here is not really needed, as we
      # only have to request data to one node.
      let accTrieNode = await proto2.getAccountTrieNode(accountTrieNodeKey)
      check accTrieNode.isSome()

      let hash = keccakHash(accTrieNode.get().node.asSeq())
      check hash.data == key

    proto1.stop()
    proto2.stop()
    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Find content in the network via content lookup":
    # TODO: Improve this test so it actually need to go through several
    # findNodes request, to properly test the lookup call.
    let
      accounts =
        getGenesisAlloc("fluffy" / "tests" / "custom_genesis" / "chainid7.json")
      (trie, _) = accounts.toState()
      node1 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20312))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20313))
      sm2 = StreamManager.new(node2)
      node3 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20314))
      sm3 = StreamManager.new(node3)

      proto1 =
        StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 =
        StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)
      proto3 =
        StateNetwork.new(node3, ContentDB.new("", uint32.high, inMemory = true), sm3)

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
          contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey
        )
        contentId = toContentId(contentKey.encode())
        value = AccountTrieNodeRetrieval(node: TrieNode.init(v))

      discard proto2.contentDB.put(
        contentId, value.encode(), proto2.portalProtocol.localNode.id
      )
      # Not needed right now as 1 node is enough considering node 1 is connected
      # to both.
      discard proto3.contentDB.put(
        contentId, value.encode(), proto3.portalProtocol.localNode.id
      )

    # Get first key
    var nodeHash: NodeHash
    let firstKey = keys[0]
    copyMem(nodeHash.data.addr, unsafeAddr firstKey[0], sizeof(nodeHash.data))

    let
      accountTrieNodeKey = AccountTrieNodeKey(nodeHash: nodeHash)
      contentKey =
        ContentKey(contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)

    let accTrieNode = await proto1.getAccountTrieNode(accountTrieNodeKey)
    check accTrieNode.isSome()

    let hash = keccakHash(accTrieNode.get().node.asSeq())
    check hash.data == firstKey

    proto1.stop()
    proto2.stop()
    await node1.closeWait()
    await node2.closeWait()
    await node3.closeWait()
