# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/algorithm,
  chronos, testutils/unittests, stew/shims/net,
  eth/keys, eth/p2p/discoveryv5/routing_table, nimcrypto/[hash, sha2],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/wire/[portal_protocol, portal_stream],
  ../content_db,
  ./test_helpers

const protocolId = [byte 0x50, 0x00]

type Default2NodeTest = ref object
  node1: discv5_protocol.Protocol
  node2: discv5_protocol.Protocol
  proto1: PortalProtocol
  proto2: PortalProtocol

proc testHandler(contentKey: ByteList): Option[ContentId] =
  # Note: Returning a static content id here, as in practice this depends
  # on the content key to content id derivation, which is different for the
  # different content networks. And we want these tests to be independent from
  # that.
  let idHash = sha256.digest("test")
  some(readUintBE[256](idHash.data))

proc testHandlerSha256(contentKey: ByteList): Option[ContentId] =
  # Note: Returning a static content id here, as in practice this depends
  # on the content key to content id derivation, which is different for the
  # different content networks. And we want these tests to be independent from
  # that.
  let idHash = sha256.digest(contentKey.asSeq())
  some(readUintBE[256](idHash.data))

proc validateContent(content: openArray[byte], contentKey: ByteList): bool =
  true

proc defaultTestCase(rng: ref BrHmacDrbgContext): Default2NodeTest =
  let
    node1 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20302))
    node2 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20303))

    db1 = ContentDB.new("", uint32.high, inMemory = true)
    db2 = ContentDB.new("", uint32.high, inMemory = true)

    proto1 =
      PortalProtocol.new(node1, protocolId, db1, testHandler, validateContent)
    proto2 =
      PortalProtocol.new(node2, protocolId, db2, testHandler, validateContent)

  Default2NodeTest(node1: node1, node2: node2, proto1: proto1, proto2: proto2)

proc stopTest(test: Default2NodeTest) {.async.} =
  test.proto1.stop()
  test.proto2.stop()
  await test.node1.closeWait()
  await test.node2.closeWait()

procSuite "Portal Wire Protocol Tests":
  let rng = newRng()

  asyncTest "Ping/Pong":
    let test = defaultTestCase(rng)

    let pong = await test.proto1.ping(test.proto2.localNode)

    let customPayload = ByteList(SSZ.encode(CustomPayload(dataRadius: UInt256.high())))

    check:
      pong.isOk()
      pong.get().enrSeq == 1'u64
      pong.get().customPayload == customPayload

    await test.stopTest()

  asyncTest "FindNodes/Nodes":
    let test = defaultTestCase(rng)

    block: # Find itself
      let nodes = await test.proto1.findNodesImpl(test.proto2.localNode,
        List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing: this should result in nothing as we haven't started
      # the seeding of the portal protocol routing table yet.
      let nodes = await test.proto1.findNodesImpl(test.proto2.localNode,
        List[uint16, 256](@[]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 0

    block: # Find for distance
      # ping in one direction to add, ping in the other to update as seen,
      # adding the node in the discovery v5 routing table. Could also launch
      # with bootstrap node instead.
      check (await test.node1.ping(test.node2.localNode)).isOk()
      check (await test.node2.ping(test.node1.localNode)).isOk()

      # Start the portal protocol to seed nodes from the discoveryv5 routing
      # table.
      test.proto2.start()

      let distance = logDistance(test.node1.localNode.id, test.node2.localNode.id)
      let nodes = await test.proto1.findNodesImpl(test.proto2.localNode,
        List[uint16, 256](@[distance]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    await test.stopTest()

  asyncTest "FindContent/Content - send enrs":
    let test = defaultTestCase(rng)

    # ping in one direction to add, ping in the other to update as seen.
    check (await test.node1.ping(test.node2.localNode)).isOk()
    check (await test.node2.ping(test.node1.localNode)).isOk()

    # Start the portal protocol to seed nodes from the discoveryv5 routing
    # table.
    test.proto2.start()

    let contentKey = ByteList.init(@[1'u8])

    # content does not exist so this should provide us with the closest nodes
    # to the content, which is the only node in the routing table.
    let content = await test.proto1.findContentImpl(test.proto2.localNode,
      contentKey)

    check:
      content.isOk()
      content.get().enrs.len() == 1

    await test.stopTest()

  asyncTest "Offer/Accept":
    let test = defaultTestCase(rng)
    let contentKeys = ContentKeysList(List(@[ByteList(@[byte 0x01, 0x02, 0x03])]))

    let accept = await test.proto1.offerImpl(
      test.proto2.baseProtocol.localNode, contentKeys)

    check:
      accept.isOk()
      accept.get().connectionId.len == 2
      accept.get().contentKeys.len == contentKeys.len

    await test.stopTest()

  asyncTest "Correctly mark node as seen after request":
    let test = defaultTestCase(rng)

    let initialNeighbours = test.proto1.neighbours(test.proto1.localNode.id,
      seenOnly = false)

    check:
      len(initialNeighbours) == 0

    discard test.proto1.addNode(test.proto2.baseProtocol.localNode)

    let allNeighboursAfterAdd = test.proto1.neighbours(
      test.proto1.localNode.id, seenOnly = false)
    let seenNeighboursAfterAdd = test.proto1.neighbours(
      test.proto1.localNode.id, seenOnly = true)

    check:
      len(allNeighboursAfterAdd) == 1
      len(seenNeighboursAfterAdd) == 0

    let pong = await test.proto1.ping(test.proto2.baseProtocol.localNode)

    let allNeighboursAfterPing = test.proto1.neighbours(
      test.proto1.localNode.id, seenOnly = false)
    let seenNeighboursAfterPing = test.proto1.neighbours(
      test.proto1.localNode.id, seenOnly = true)

    check:
      pong.isOk()
      len(allNeighboursAfterPing) == 1
      len(seenNeighboursAfterPing) == 1

    await test.stopTest()

  asyncTest "Lookup nodes":
      let
        node1 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20302))
        node2 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20303))
        node3 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20304))

        db1 = ContentDB.new("", uint32.high, inMemory = true)
        db2 = ContentDB.new("", uint32.high, inMemory = true)
        db3 = ContentDB.new("", uint32.high, inMemory = true)

        proto1 = PortalProtocol.new(
          node1, protocolId, db1, testHandler, validateContent)
        proto2 = PortalProtocol.new(
          node2, protocolId, db2, testHandler, validateContent)
        proto3 = PortalProtocol.new(
          node3, protocolId, db3, testHandler, validateContent)

      # Node1 knows about Node2, and Node2 knows about Node3 which hold all content
      check proto1.addNode(node2.localNode) == Added
      check proto2.addNode(node3.localNode) == Added

      check (await proto2.ping(node3.localNode)).isOk()

      let lookuResult = await proto1.lookup(node3.localNode.id)

      check:
        # returned result should contain node3 as it is in node2 routing table
        lookuResult.contains(node3.localNode)

      await node1.closeWait()
      await node2.closeWait()
      await node3.closeWait()

  asyncTest "Content lookup should return info about nodes interested in content":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))
      node3 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20304))

      db1 = ContentDB.new("", uint32.high, inMemory = true)
      db2 = ContentDB.new("", uint32.high, inMemory = true)
      db3 = ContentDB.new("", uint32.high, inMemory = true)

      proto1 = PortalProtocol.new(
        node1, protocolId, db1, testHandlerSha256, validateContent)
      proto2 = PortalProtocol.new(
        node2, protocolId, db2, testHandlerSha256, validateContent)
      proto3 = PortalProtocol.new(
        node3, protocolId, db3, testHandlerSha256, validateContent)

      content = @[byte 1, 2]
      contentList = List[byte, 2048].init(content)
      contentId = readUintBE[256](sha256.digest(content).data)

    # Only node3 have content
    discard db3.put(contentId, content, proto3.localNode.id)

    # Node1 knows about Node2, and Node2 knows about Node3 which hold all content
    # Node1 needs to known Node2 radius to determine if node2 is interested in content
    check proto1.addNode(node2.localNode) == Added
    check proto2.addNode(node3.localNode) == Added

    check (await proto1.ping(node2.localNode)).isOk()
    check (await proto2.ping(node3.localNode)).isOk()

    let lookupResult = await proto1.contentLookup(contentList, contentId)

    check:
      lookupResult.isSome()

    let res = lookupResult.unsafeGet()

    check:
      res.content == content
      res.nodesInterestedInContent.contains(node2.localNode)

    await node1.closeWait()
    await node2.closeWait()
    await node3.closeWait()

  asyncTest "Valid Bootstrap Node":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      db1 = ContentDB.new("", uint32.high, inMemory = true)
      db2 = ContentDB.new("", uint32.high, inMemory = true)

      proto1 = PortalProtocol.new(
        node1, protocolId, db1, testHandler, validateContent)
      proto2 = PortalProtocol.new(
        node2, protocolId, db2, testHandler, validateContent,
        bootstrapRecords = [node1.localNode.record])

    proto1.start()
    proto2.start()

    check proto2.neighbours(proto2.localNode.id).len == 1

    proto1.stop()
    proto2.stop()
    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Invalid Bootstrap Node":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      db = ContentDB.new("", uint32.high, inMemory = true)
      # No portal protocol for node1, hence an invalid bootstrap node
      proto2 = PortalProtocol.new(node2, protocolId, db, testHandler,
        validateContent, bootstrapRecords = [node1.localNode.record])

    # seedTable to add node1 to the routing table
    proto2.seedTable()
    check proto2.neighbours(proto2.localNode.id).len == 1

    # This should fail and drop node1 from the routing table
    await proto2.revalidateNode(node1.localNode)

    check proto2.neighbours(proto2.localNode.id).len == 0

    proto2.stop()
    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Adjusting radius after hitting full database":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      dbLimit = 100000'u32
      db = ContentDB.new("", dbLimit, inMemory = true)
      proto1 = PortalProtocol.new(node1, protocolId, db, testHandler,
        validateContent)

    let item = genByteSeq(10000)
    var distances: seq[UInt256] = @[]

    for i in 0..8:
      proto1.storeContent(u256(i), item)
      distances.add(u256(i) xor proto1.localNode.id)
    
    # With current setting i.e limit 100000bytes and 10000 byte element each
    # two furthest elements should be delted i.e index 0 and 1.
    # index 2 should be still be in database and it distance should always be
    # <= updated radius
    distances.sort(order = SortOrder.Descending)

    check:
      db.get((distances[0] xor proto1.localNode.id)).isNone()
      db.get((distances[1] xor proto1.localNode.id)).isNone()
      db.get((distances[2] xor proto1.localNode.id)).isSome()
      # our radius have been updated and is lower than max
      proto1.dataRadius < UInt256.high
      # but higher or equal to furthest non deleted element
      proto1.dataRadius >= distances[2]

    proto1.stop()
    await node1.closeWait()
