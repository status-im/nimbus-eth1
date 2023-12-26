# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, json, sequtils, strutils, sugar],
  stew/[byteutils, io2],
  nimcrypto/hash,
  testutils/unittests, chronos,
  eth/trie/hexary_proof_verification,
  eth/keys,
  eth/common/[eth_types, eth_hash],
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  ../tools/state_bridge/state_bridge,
  ../../nimbus/[config, db/core_db, db/state_db],
  ../../nimbus/common/[chain_config, genesis],
  ../network/wire/[portal_protocol, portal_stream],
  ../network/state/[state_content, state_network],
  ../database/content_db,
  ./test_helpers

const testVectorDir =
  "./vendor/portal-spec-tests/tests/mainnet/state/"

proc genesisToTrie(filePath: string): CoreDbMptRef =
  # TODO: Doing our best here with API that exists, to be improved.
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  let sdb  = newStateDB(newCoreDbRef LegacyDbMemory, false)
  let map  = toForkTransitionTable(cn.config)
  let fork = map.toHardFork(forkDeterminationInfo(0.toBlockNumber, cn.genesis.timestamp))
  discard toGenesisHeader(cn.genesis, sdb, fork)

  sdb.getTrie

procSuite "State Content Network":
  let rng = newRng()

  test "Encode/decode accountTrieProofKey":
    const
      address = "0x000d836201318ec6899a67540690382780743280"
      stateRoot = "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      hexKey = "0x000d836201318ec6899a67540690382780743280d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"

    let
      addressBytes = hexToByteArray[20](address)
      stateRootBytes = hexToByteArray[sizeof(state_content.AccountTrieProofKey.stateRoot)](stateRoot)
      key = AccountTrieProofKey(address: addressBytes, stateRoot: stateRootBytes)

    let encodedKey = SSZ.encode(key)
    check encodedKey.to0xHex() == hexKey
    let decodedKey = decodeSsz(encodedKey, AccountTrieProofKey)
    check decodedKey.isOk()

  asyncTest "Encode/decode accountTrieProof":
    let file = testVectorDir & "/proofs.full.block.0.json"
    let content = readAllFile(file).valueOr:
      quit(1)

    let decoded =
      try:
        Json.decode(content, state_bridge.JsonProofVector)
      except SerializationError:
        quit(1)

    let proof = decoded.proofs[0].proof.map(hexToSeqByte)

    var accountTrieProof = AccountTrieProof(@[])
    for witness in proof:
      let witnessNode = ByteList(witness)
      discard accountTrieProof.add(witnessNode)

    let
      encodedProof = SSZ.encode(accountTrieProof)
      decodedProof = decodeSsz(encodedProof, AccountTrieProof).get()

    check decodedProof == accountTrieProof


  asyncTest "Test account state proof":
    let file = testVectorDir & "/proofs.full.block.0.json"
    let content = readAllFile(file).valueOr:
      quit(1)

    let decoded =
      try:
        Json.decode(content, state_bridge.JsonProofVector)
      except SerializationError:
        quit(1)
    let
      proof = decoded.proofs[0].proof.map(hexToSeqByte)
      stateRoot = MDigest[256].fromHex(decoded.state_root)
      address = hexToByteArray[20](decoded.proofs[0].address)
      key = keccakHash(address).data.toSeq()
      value = proof[^1].decode(seq[seq[byte]])[^1]
      proofResult = verifyMptProof(proof, stateRoot, key, value)
    check proofResult.kind == ValidProof

  asyncTest "Decode and use proofs":
    let file = testVectorDir & "/proofs.full.block.0.json"
    let content = readAllFile(file).valueOr:
      quit(1)

    let decoded =
      try:
        Json.decode(content, state_bridge.JsonProofVector)
      except SerializationError:
        quit(1)

    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      sm1 = StreamManager.new(node1)
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      sm2 = StreamManager.new(node2)

      proto1 = StateNetwork.new(node1, ContentDB.new("", uint32.high, inMemory = true), sm1)
      proto2 = StateNetwork.new(node2, ContentDB.new("", uint32.high, inMemory = true), sm2)

      state_root = hexToByteArray[sizeof(state_content.AccountTrieProofKey.stateRoot)](decoded.state_root)

    check proto2.portalProtocol.addNode(node1.localNode) == Added


    for proof in decoded.proofs:
      let
        address = hexToByteArray[sizeof(state_content.Address)](proof.address)
        key = AccountTrieProofKey(
          address: address,
          stateRoot: state_root)
        contentKey = ContentKey(
          contentType: state_content.ContentType.accountTrieProof,
          accountTrieProofKey: key)

      var accountTrieProof = AccountTrieProof(@[])
      for witness in proof.proof:
        let witnessNode = ByteList(hexToSeqByte(witness))
        discard accountTrieProof.add(witnessNode)
      
      let encodedValue = SSZ.encode(accountTrieProof)

      discard proto1.contentDB.put(contentKey.toContentId(), encodedValue, proto1.portalProtocol.localNode.id)

      let foundContent = await proto2.getContent(contentKey)

      check foundContent.isSome()

      check decodeSsz(foundContent.get(), AccountTrieProof).isOk()

    await node1.closeWait()
    await node2.closeWait()


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
