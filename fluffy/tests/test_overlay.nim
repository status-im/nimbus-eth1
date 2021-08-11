# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, testutils/unittests, stew/shims/net,
  eth/keys, eth/p2p/discoveryv5/routing_table,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/overlay/overlay_protocol,
  ./test_helpers

proc random(T: type UInt256, rng: var BrHmacDrbgContext): T =
  var key: UInt256
  brHmacDrbgGenerate(addr rng, addr key, csize_t(sizeof(key)))

  key

procSuite "Overlay Tests":
  let rng = newRng()

  asyncTest "Overlay Ping/Pong compatible protocols":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      node1Payload = List.init(@[1'u8], 2048)
      node2Payload = List.init(@[2'u8], 2048)

      # Both nodes support same protocol with different payloads
      node1Sub = SubProtocolDefinition(subProtocolId: @[1'u8], subProtocolPayLoad: node1Payload)
      node2Sub = SubProtocolDefinition(subProtocolId: @[1'u8], subProtocolPayLoad: node2Payload)

      proto1 = OverlayProtocol.new(node1)
      proto2 = OverlayProtocol.new(node2)

      sub1 = proto1.registerSubProtocol(node1Sub)
      sub2 = proto2.registerSubProtocol(node2Sub)

    let pong = await sub1.ping(proto2.baseProtocol.localNode)

    check:
      pong.isOk()
      pong.get().enrSeq == 1'u64
      pong.get().subProtocolPayload == node2Payload

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Overlay Ping/Pong in-compatible protocols":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      node1Payload = List.init(@[1'u8], 2048)
      node2Payload = List.init(@[2'u8], 2048)

      # Both nodes support same protocol with different payloads
      node1Sub = SubProtocolDefinition(subProtocolId: @[1'u8], subProtocolPayLoad: node1Payload)
      node2Sub = SubProtocolDefinition(subProtocolId: @[2'u8], subProtocolPayLoad: node2Payload)

      proto1 = OverlayProtocol.new(node1)
      proto2 = OverlayProtocol.new(node2)

      sub1 = proto1.registerSubProtocol(node1Sub)
      sub2 = proto2.registerSubProtocol(node2Sub)

    let pong = await sub1.ping(proto2.baseProtocol.localNode)

    check:
      pong.isErr()

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Overlay FindNode/Nodes":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      node1Payload = List.init(@[1'u8], 2048)
      node2Payload = List.init(@[2'u8], 2048)

      supportedProto = @[1'u8]

      # Both nodes support same protocol with different payloads
      node1Sub = SubProtocolDefinition(subProtocolId: supportedProto, subProtocolPayLoad: node1Payload)
      node2Sub = SubProtocolDefinition(subProtocolId: supportedProto, subProtocolPayLoad: node2Payload)

      proto1 = OverlayProtocol.new(node1)
      proto2 = OverlayProtocol.new(node2)

      sub1 = proto1.registerSubProtocol(node1Sub)
      sub2 = proto2.registerSubProtocol(node2Sub)

    block: # Find itself
      let nodes = await sub1.findNode(proto2.baseProtocol.localNode,
        List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing: this should result in nothing as we haven't started
      # the seeding of the portal protocol routing table yet.
      let nodes = await sub1.findNode(proto2.baseProtocol.localNode,
        List[uint16, 256](@[]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 0

    block: # Find for distance
      # ping in one direction to add, ping in the other to update as seen,
      # adding the node in the discovery v5 routing table. Could also launch
      # with bootstrap node instead.
      check (await node1.ping(node2.localNode)).isOk()
      check (await node2.ping(node1.localNode)).isOk()

      # Start the portal protocol to seed nodes from the discoveryv5 routing
      # table.
      sub2.start()

      let distance = logDist(node1.localNode.id, node2.localNode.id)
      let nodes = await sub1.findNode(proto2.baseProtocol.localNode,
        List[uint16, 256](@[distance]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    sub2.stop()
    await node1.closeWait()
    await node2.closeWait()
