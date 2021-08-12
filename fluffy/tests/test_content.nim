import
  chronos, testutils/unittests, stew/shims/net,
  eth/keys, eth/p2p/discoveryv5/routing_table,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/ssz/ssz_serialization,
  ../network/content/content_protocol,
  ../network/overlay/overlay_protocol,
  ./test_helpers

procSuite "Content Tests":
  let rng = newRng()

  let expectedRequest = ByteList(@[1'u8, 2'u8])

  let expectedResult = ByteList(@[1'u8, 2'u8, 3'u8])

  proc handler(req: ByteList): Option[List[byte, 2048]] = 
    if (req == expectedRequest):
      some(expectedResult)
    else:
      none[ByteList]()

  proc init2ConentSubProtocols(
    node1: discv5_protocol.Protocol, 
    node2: discv5_protocol.Protocol): (ContentSubprotocol, ContentSubprotocol) =
      # TODO Think about better api to initialize protocols composed from few
      # subprotocols
      let
        node1Payload = List.init(@[1'u8], 2048)
        node2Payload = List.init(@[2'u8], 2048)

        # Both nodes support same protocol with different payloads
        node1Sub = SubProtocolDefinition(subProtocolId: @[1'u8], subProtocolPayLoad: node1Payload)
        node2Sub = SubProtocolDefinition(subProtocolId: @[1'u8], subProtocolPayLoad: node2Payload)

        proto1 = OverlayProtocol.new(node1)
        proto2 = OverlayProtocol.new(node2)

        sub1 = proto1.registerSubProtocol(node1Sub)
        sub2 = proto2.registerSubProtocol(node2Sub)
        
        cont1 = ContentProtocol.new(node1)
        cont2 = ContentProtocol.new(node2)

        contentSub1 = cont1.registerContentSubProtocol(sub1, handler)
        contentSub2 = cont2.registerContentSubProtocol(sub2, handler)
      return (contentSub1, contentSub2)

  asyncTest "Find content when content is present on remote node":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      (contentSub1, contentSub2) = init2ConentSubProtocols(node1, node2)

    let fcResult = await contentSub1.findContent(contentSub2.baseProtocol.localNode, expectedRequest)

    check:
      fcResult.isOk()
      fcResult.get().payload == expectedResult
      len(fcResult.get().enrs) == 0

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Find closer nodes when content is not present on remote node":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      (contentSub1, contentSub2) = init2ConentSubProtocols(node1, node2)

    # ping in one direction to add, ping in the other to update as seen.
    check (await node1.ping(node2.localNode)).isOk()
    check (await node2.ping(node1.localNode)).isOk()

    contentSub2.start()

    let notKnownKey = ByteList(@[1'u8])
    let fcResult = await contentSub1.findContent(contentSub2.baseProtocol.localNode, notKnownKey)

    check:
      fcResult.isOk()
      len(fcResult.get().payload) == 0
      len(fcResult.get().enrs) == 1

    contentSub2.stop()
    await node1.closeWait()
    await node2.closeWait()
