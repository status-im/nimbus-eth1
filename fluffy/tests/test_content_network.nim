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
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../nimbus/[genesis, chain_config, db/db_chain],
  ../network/state/portal_protocol, ../network/state/content, ../network/state/portal_network,
  ./test_helpers

proc genesisToTrie(filePath: string): HexaryTrie =
  # TODO: Doing our best here with API that exists, to be improved.
  var cg: CustomGenesis
  if not loadCustomGenesis(filePath, cg):
    quit(1)

  var chainDB = newBaseChainDB(
    newMemoryDb(),
    pruneTrie = false
  )
  # TODO: Can't provide this at the `newBaseChainDB` call, need to adjust API
  chainDB.config = cg.config
  # TODO: this actually also creates a HexaryTrie and AccountStateDB, which we
  # could skip
  let header = toBlock(cg.genesis, chainDB)

  # Trie exists already in flat db, but need to provide the root
  initHexaryTrie(chainDB.db, header.stateRoot, chainDB.pruneTrie)

procSuite "Content Network":
  let rng = newRng()
  asyncTest "Test Share Full State":
    let
      trie = genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")

      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalNetwork.new(node1, ContentStorage(trie: trie))
      proto2 = PortalNetwork.new(node2, ContentStorage(trie: trie))


    var keys: seq[seq[byte]]
    for k, v in trie.replicate:
      keys.add(k)

    for key in keys:
      var nodeHash: NodeHash
      copyMem(nodeHash.data.addr, unsafeAddr key[0], sizeof(nodeHash.data))

      let
        contentKey = ContentKey(
          networkId: 0'u16,
          contentType: content.ContentType.Account,
          nodeHash: nodeHash)

      let foundContent = await proto2.findContent(
        contentKey,
        proto1.proto.baseProtocol.localNode
      )

      check:
        foundContent.isSome()

      let hash = hexary.keccak(foundContent.get())
      check hash.data == key
    await node1.closeWait()
    await node2.closeWait()
