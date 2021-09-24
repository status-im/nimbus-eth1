# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, testutils/unittests, stew/shims/net, stew/byteutils,
  eth/keys, eth/p2p/discoveryv5/routing_table, nimcrypto/[hash, sha2],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/wire/portal_protocol,
  ./test_helpers

const protocolId = "portal".toBytes()

type Default2NodeTest = ref object
  node1: discv5_protocol.Protocol
  node2: discv5_protocol.Protocol
  proto1: PortalProtocol
  proto2: PortalProtocol

proc testHandler(contentKey: ByteList): ContentResult =
  let
    idHash = sha256.digest("test")
    id = readUintBE[256](idHash.data)
  # TODO: Ideally we can return here a more valid content id. But that depends
  # on the content key to content id derivation, which is different for the
  # different content networks. And we want these tests to be independent from
  # that. Could do something specifically for these tests, when there is a test
  # case that would actually test this.
  ContentResult(kind: ContentMissing, contentId: id)

proc defaultTestCase(rng: ref BrHmacDrbgContext): Default2NodeTest =
  let
    node1 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20302))
    node2 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20303))

    proto1 = PortalProtocol.new(node1, protocolId, testHandler)
    proto2 = PortalProtocol.new(node2, protocolId, testHandler)

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

    check:
      pong.isOk()
      pong.get().enrSeq == 1'u64
      pong.get().dataRadius == UInt256.high()

    await test.stopTest()

  asyncTest "FindNode/Nodes":
    let test = defaultTestCase(rng)
  
    block: # Find itself
      let nodes = await test.proto1.findNode(test.proto2.localNode,
        List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing: this should result in nothing as we haven't started
      # the seeding of the portal protocol routing table yet.
      let nodes = await test.proto1.findNode(test.proto2.localNode,
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

      let distance = logDist(test.node1.localNode.id, test.node2.localNode.id)
      let nodes = await test.proto1.findNode(test.proto2.localNode,
        List[uint16, 256](@[distance]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1
    
    await test.stopTest()

  asyncTest "FindContent/FoundContent - send enrs":
    let test = defaultTestCase(rng)

    # ping in one direction to add, ping in the other to update as seen.
    check (await test.node1.ping(test.node2.localNode)).isOk()
    check (await test.node2.ping(test.node1.localNode)).isOk()

    # Start the portal protocol to seed nodes from the discoveryv5 routing
    # table.
    test.proto2.start()

    let contentKey = List.init(@[1'u8], 2048)

    # content does not exist so this should provide us with the closest nodes
    # to the content, which is the only node in the routing table.
    let foundContent = await test.proto1.findContent(test.proto2.localNode,
      contentKey)

    check:
      foundContent.isOk()
      foundContent.get().enrs.len() == 1
      foundContent.get().payload.len() == 0

    await test.stopTest()

  asyncTest "Offer/Accept":
    let test = defaultTestCase(rng)
    let contentKeys = ContentKeysList(List(@[ByteList(@[byte 0x01, 0x02, 0x03])]))

    let accept = await test.proto1.offer(
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

        proto1 = PortalProtocol.new(node1, protocolId, testHandler)
        proto2 = PortalProtocol.new(node2, protocolId, testHandler)
        proto3 = PortalProtocol.new(node3, protocolId, testHandler)

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

  asyncTest "Valid Bootstrap Node":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalProtocol.new(node1, protocolId, testHandler)
      proto2 = PortalProtocol.new(node2, protocolId, testHandler,
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

      # No portal protocol for node1, hence an invalid bootstrap node
      proto2 = PortalProtocol.new(node2, protocolId, testHandler,
        bootstrapRecords = [node1.localNode.record])

    # seedTable to add node1 to the routing table
    proto2.seedTable()
    check proto2.neighbours(proto2.localNode.id).len == 1

    # This should fail and drop node1 from the routing table
    await proto2.revalidateNode(node1.localNode)

    check proto2.neighbours(proto2.localNode.id).len == 0

    proto2.stop()
    await node1.closeWait()
    await node2.closeWait()
