# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, testutils/unittests, stew/shims/net,
  eth/keys, eth/p2p/discoveryv5/routing_table, nimcrypto/[hash, sha2],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/state/portal_protocol,
  ./test_helpers

type Default2NodeTest = ref object
  node1: discv5_protocol.Protocol
  node2: discv5_protocol.Protocol
  proto1: PortalProtocol
  proto2: PortalProtocol

proc testHandler(contentKey: ByteList): ContentResult =
  let id =  sha256.digest("test")
  ContentResult(kind: ContentMissing, contentId: id)

proc defaultTestCase(rng: ref BrHmacDrbgContext): Default2NodeTest =
  let
    node1 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20302))
    node2 = initDiscoveryNode(
      rng, PrivateKey.random(rng[]), localAddress(20303))

    proto1 = PortalProtocol.new(node1, testHandler)
    proto2 = PortalProtocol.new(node2, testHandler)

  Default2NodeTest(node1: node1, node2: node2, proto1: proto1, proto2: proto2)

proc stopTest(test: Default2NodeTest) {.async.} =
  test.proto1.stop()
  test.proto2.stop()
  await test.node1.closeWait()
  await test.node2.closeWait()

procSuite "Portal Tests":
  let rng = newRng()

  asyncTest "Portal Ping/Pong":
    let test = defaultTestCase(rng)

    let pong = await test.proto1.ping(test.proto2.baseProtocol.localNode)

    check:
      pong.isOk()
      pong.get().enrSeq == 1'u64
      pong.get().dataRadius == UInt256.high()

    await test.stopTest()

  asyncTest "Portal correctly mark node as seen after request":
    let test = defaultTestCase(rng)
  
    let initialNeighbours = test.proto1.neighbours(test.proto1.baseProtocol.localNode.id, seenOnly = false)

    check:
      len(initialNeighbours) == 0

    discard test.proto1.addNode(test.proto2.baseProtocol.localNode)
    
    let allNeighboursAfterAdd = test.proto1.neighbours(test.proto1.baseProtocol.localNode.id, seenOnly = false)
    let seenNeighboursAfterAdd = test.proto1.neighbours(test.proto1.baseProtocol.localNode.id, seenOnly = true)

    check:
      len(allNeighboursAfterAdd) == 1
      len(seenNeighboursAfterAdd) == 0

    let pong = await test.proto1.ping(test.proto2.baseProtocol.localNode)

    let allNeighboursAfterPing = test.proto1.neighbours(test.proto1.baseProtocol.localNode.id, seenOnly = false)
    let seenNeighboursAfterPing = test.proto1.neighbours(test.proto1.baseProtocol.localNode.id, seenOnly = true)

    check:
      pong.isOk()
      len(allNeighboursAfterPing) == 1
      len(seenNeighboursAfterPing) == 1

    await test.stopTest()

  asyncTest "Portal FindNode/Nodes":
    let test = defaultTestCase(rng)
  
    block: # Find itself
      let nodes = await test.proto1.findNode(test.proto2.baseProtocol.localNode,
        List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing: this should result in nothing as we haven't started
      # the seeding of the portal protocol routing table yet.
      let nodes = await test.proto1.findNode(test.proto2.baseProtocol.localNode,
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
      let nodes = await test.proto1.findNode(test.proto2.baseProtocol.localNode,
        List[uint16, 256](@[distance]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1
    
    await test.stopTest()

  asyncTest "Portal lookup nodes":
      let
        node1 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20302))
        node2 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20303))
        node3 = initDiscoveryNode(
          rng, PrivateKey.random(rng[]), localAddress(20304))

        proto1 = PortalProtocol.new(node1, testHandler)
        proto2 = PortalProtocol.new(node2, testHandler)
        proto3 = PortalProtocol.new(node3, testHandler)

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


  asyncTest "Portal FindContent/FoundContent - send enrs":
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
    let foundContent = await test.proto1.findContent(test.proto2.baseProtocol.localNode,
      contentKey)

    check:
      foundContent.isOk()
      foundContent.get().enrs.len() == 1
      foundContent.get().payload.len() == 0

    await test.stopTest()

