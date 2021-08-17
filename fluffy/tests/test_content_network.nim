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
  ../../nimbus/[genesis, chain_config, db/db_chain],
  ../network/state/portal_protocol, ../network/state/content,
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
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalProtocol.new(node1)
      proto2 = PortalProtocol.new(node2)

    let trie =
      genesisToTrie("fluffy" / "tests" / "custom_genesis" / "chainid7.json")

    proto1.contentStorage = ContentStorage(trie: trie)

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

      let foundContent = await proto2.findContent(proto1.baseProtocol.localNode,
        contentKey)

      check:
        foundContent.isOk()
        foundContent.get().payload.len() != 0
        foundContent.get().enrs.len() == 0

      let hash = hexary.keccak(foundContent.get().payload.asSeq())
      check hash.data == key
