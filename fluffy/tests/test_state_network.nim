# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, json, sequtils, strutils],
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

  asyncTest "Test account state proof":
    let proof = [
      "0xf90211a090dcaf88c40c7bbc95a912cbdde67c175767b31173df9ee4b0d733bfdd511c43a0babe369f6b12092f49181ae04ca173fb68d1a5456f18d20fa32cba73954052bda0473ecf8a7e36a829e75039a3b055e51b8332cbf03324ab4af2066bbd6fbf0021a0bbda34753d7aa6c38e603f360244e8f59611921d9e1f128372fec0d586d4f9e0a04e44caecff45c9891f74f6a2156735886eedf6f1a733628ebc802ec79d844648a0a5f3f2f7542148c973977c8a1e154c4300fec92f755f7846f1b734d3ab1d90e7a0e823850f50bf72baae9d1733a36a444ab65d0a6faaba404f0583ce0ca4dad92da0f7a00cbe7d4b30b11faea3ae61b7f1f2b315b61d9f6bd68bfe587ad0eeceb721a07117ef9fc932f1a88e908eaead8565c19b5645dc9e5b1b6e841c5edbdfd71681a069eb2de283f32c11f859d7bcf93da23990d3e662935ed4d6b39ce3673ec84472a0203d26456312bbc4da5cd293b75b840fc5045e493d6f904d180823ec22bfed8ea09287b5c21f2254af4e64fca76acc5cd87399c7f1ede818db4326c98ce2dc2208a06fc2d754e304c48ce6a517753c62b1a9c1d5925b89707486d7fc08919e0a94eca07b1c54f15e299bd58bdfef9741538c7828b5d7d11a489f9c20d052b3471df475a051f9dd3739a927c89e357580a4c97b40234aa01ed3d5e0390dc982a7975880a0a089d613f26159af43616fd9455bb461f4869bfede26f2130835ed067a8b967bfb80",
      "0xf90211a0dae48f5b47930c28bb116fbd55e52cd47242c71bf55373b55eb2805ee2e4a929a00f1f37f337ec800e2e5974e2e7355f10f1a4832b39b846d916c3597a460e0676a0da8f627bb8fbeead17b318e0a8e4f528db310f591bb6ab2deda4a9f7ca902ab5a0971c662648d58295d0d0aa4b8055588da0037619951217c22052802549d94a2fa0ccc701efe4b3413fd6a61a6c9f40e955af774649a8d9fd212d046a5a39ddbb67a0d607cdb32e2bd635ee7f2f9e07bc94ddbd09b10ec0901b66628e15667aec570ba05b89203dc940e6fa70ec19ad4e01d01849d3a5baa0a8f9c0525256ed490b159fa0b84227d48df68aecc772939a59afa9e1a4ab578f7b698bdb1289e29b6044668ea0fd1c992070b94ace57e48cbf6511a16aa770c645f9f5efba87bbe59d0a042913a0e16a7ccea6748ae90de92f8aef3b3dc248a557b9ac4e296934313f24f7fced5fa042373cf4a00630d94de90d0a23b8f38ced6b0f7cb818b8925fee8f0c2a28a25aa05f89d2161c1741ff428864f7889866484cef622de5023a46e795dfdec336319fa07597a017664526c8c795ce1da27b8b72455c49657113e0455552dbc068c5ba31a0d5be9089012fda2c585a1b961e988ea5efcd3a06988e150a8682091f694b37c5a0f7b0352e38c315b2d9a14d51baea4ddee1770974c806e209355233c3c89dce6ea049bf6e8df0acafd0eff86defeeb305568e44d52d2235cf340ae15c6034e2b24180",
      "0xf901f1a0cf67e0f5d5f8d70e53a6278056a14ddca46846f5ef69c7bde6810d058d4a9eda80a06732ada65afd192197fe7ce57792a7f25d26978e64e954b7b84a1f7857ac279da05439f8d011683a6fc07efb90afca198fd7270c795c835c7c85d91402cda992eaa0449b93033b6152d289045fdb0bf3f44926f831566faa0e616b7be1abaad2cb2da031be6c3752bcd7afb99b1bb102baf200f8567c394d464315323a363697646616a0a40e3ed11d906749aa501279392ffde868bd35102db41364d9c601fd651f974aa0044bfa4fe8dd1a58e6c7144da79326e94d1331c0b00373f6ae7f3662f45534b7a098005e3e48db68cb1dc9b9f034ff74d2392028ddf718b0f2084133017da2c2e7a02a62bc40414ee95b02e202a9e89babbabd24bef0abc3fc6dcd3e9144ceb0b725a0239facd895bbf092830390a8676f34b35b29792ae561f196f86614e0448a5792a0a4080f88925daff6b4ce26d188428841bd65655d8e93509f2106020e76d41eefa04918987904be42a6894256ca60203283d1b89139cf21f09f5719c44b8cdbb8f7a06201fc3ef0827e594d953b5e3165520af4fceb719e11cc95fd8d3481519bfd8ca05d0e353d596bd725b09de49c01ede0f29023f0153d7b6d401556aeb525b2959ba0cd367d0679950e9c5f2aa4298fd4b081ade2ea429d71ff390c50f8520e16e30880",
      "0xf87180808080808080a0dbee8b33c73b86df839f309f7ac92eee19836e08b39302ffa33921b3c6a09f66a06068b283d51aeeee682b8fb5458354315d0b91737441ede5e137c18b4775174a8080808080a0fe7779c7d58c2fda43eba0a6644043c86ebb9ceb4836f89e30831f23eb059ece8080",
      "0xf8719f20b71c90b0d523dd5004cf206f325748da347685071b34812e21801f5270c4b84ff84d80890ad78ebc5ac6200000a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    ].map(hexToSeqByte)
    let stateRoot = MDigest[256].fromHex("0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544")
    let address = hexToByteArray[20]("0x000d836201318ec6899a67540690382780743280")
    let key = keccakHash(address).data.toSeq()
    let value = proof[4]
    let proofResult = verifyMptProof(proof, stateRoot, key, value)
    info ">>> proofResult: ", proofResult
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

      state_root = hexToByteArray[sizeof(state_content.StateRoot)](decoded.state_root)

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
      let
        state = proof.state
        account = Account(
          nonce: state.nonce.uint64(),
          balance: UInt256.fromHex(state.balance),
          storageRoot: MDigest[256].fromHex(state.storage_hash),
          codeHash: MDigest[256].fromHex(state.code_hash))
        accountState = AccountState(
          account: account,
          proof: accountTrieProof)
        encodedValue = SSZ.encode(accountState)

      discard proto1.contentDB.put(contentKey.toContentId(), encodedValue, proto1.portalProtocol.localNode.id)

      let foundContent = await proto2.getContent(contentKey)

      check foundContent.isSome()

      var decoded = decodeSsz(foundContent.get(), AccountState).get()
      check decoded.account.nonce == 0
      check decoded.account.balance.toHex() == "ad78ebc5ac6200000"
      check toLowerAscii($decoded.account.storageRoot) == "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
      check toLowerAscii($decoded.account.codeHash) == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

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
