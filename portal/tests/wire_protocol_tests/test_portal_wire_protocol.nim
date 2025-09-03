# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/[algorithm, sequtils],
  minilru,
  chronos,
  testutils/unittests,
  results,
  eth/common/keys,
  eth/p2p/discoveryv5/routing_table,
  nimcrypto/[hash, sha2],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../network/wire/[
    portal_protocol, portal_stream, portal_protocol_config, portal_protocol_version,
    ping_extensions,
  ],
  ../../database/content_db,
  ../test_helpers

const
  protocolId = [byte 0x50, 0x00]
  connectionTimeoutTest = 2.seconds

proc toContentId(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  # Note: Returning sha256 digest as content id here. This content key to
  # content id derivation is different for the different content networks
  # and their content types.
  let idHash = sha256.digest(contentKey.asSeq())
  ok(readUintBE[256](idHash.data))

proc initPortalProtocol(
    rng: ref HmacDrbgContext,
    privKey: PrivateKey,
    address: Address,
    bootstrapRecords: openArray[Record] = [],
): PortalProtocol =
  let
    d = initDiscoveryNode(
      rng,
      privKey,
      address,
      bootstrapRecords,
      localEnrFields = {portalVersionKey: SSZ.encode(localSupportedVersions)},
    )
    db = ContentDB.new(
      "", uint32.high, RadiusConfig(kind: Dynamic), d.localNode.id, inMemory = true
    )
    manager = StreamManager.new(d)
    q = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)
    stream = manager.registerNewStream(q, connectionTimeout = connectionTimeoutTest)

  var config = defaultPortalProtocolConfig
  config.disableBanNodes = false

  let proto = PortalProtocol.new(
    d,
    protocolId,
    toContentId,
    createGetHandler(db),
    createStoreHandler(db, defaultRadiusConfig),
    createContainsHandler(db),
    createRadiusHandler(db),
    stream,
    bootstrapRecords = bootstrapRecords,
    config = config,
  )

  return proto

proc stopPortalProtocol(proto: PortalProtocol) {.async.} =
  await proto.stop()
  await proto.baseProtocol.closeWait()

proc defaultTestSetup(rng: ref HmacDrbgContext): (PortalProtocol, PortalProtocol) =
  let
    proto1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
    proto2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))

  (proto1, proto2)

procSuite "Portal Wire Protocol Tests":
  let rng = newRng()

  asyncTest "Ping/Pong":
    let (proto1, proto2) = defaultTestSetup(rng)

    let pong = await proto1.ping(proto2.localNode)

    let customPayload = CapabilitiesPayload(
      client_info: NIMBUS_PORTAL_CLIENT_INFO,
      data_radius: UInt256.high(),
      capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(
        proto1.pingExtensionCapabilities.toSeq()
      ),
    )

    check pong.isOk()

    let (enrSeq, payloadType, payload) = pong.value()
    check:
      enrSeq == 1'u64
      payloadType == 0
      payload == customPayload

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "FindNodes/Nodes":
    let (proto1, proto2) = defaultTestSetup(rng)

    block: # Find itself
      let nodes =
        await proto1.findNodesImpl(proto2.localNode, List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing: this should result in nothing as we haven't started
      # the seeding of the portal protocol routing table yet.
      let nodes = await proto1.findNodesImpl(proto2.localNode, List[uint16, 256](@[]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 0

    block: # Find for distance
      # ping in one direction to add, ping in the other to update as seen,
      # adding the node in the discovery v5 routing table. Could also launch
      # with bootstrap node instead.
      check (await proto1.baseProtocol.ping(proto2.localNode)).isOk()
      check (await proto2.baseProtocol.ping(proto1.localNode)).isOk()

      # Start the portal protocol to seed nodes from the discoveryv5 routing
      # table.
      proto2.start()

      let distance = logDistance(proto1.localNode.id, proto2.localNode.id)
      let nodes =
        await proto1.findNodesImpl(proto2.localNode, List[uint16, 256](@[distance]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "FindContent/Content - send enrs":
    let
      proto1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20402))
      proto2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20403))
      proto3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20404))

    # Make node1 know about node2, and node2 about node3
    check proto1.addNode(proto2.localNode) == Added
    check proto2.addNode(proto3.localNode) == Added

    # node1 needs to know the radius of the nodes to determine if they are
    # interested in content, so a ping is done.
    check (await proto1.ping(proto2.localNode)).isOk()
    check (await proto2.ping(proto3.localNode)).isOk()

    let contentKey = ContentKeyByteList.init(@[1'u8])

    # content does not exist so this should provide us with the closest nodes
    # to the content, which should only be node 3 because node 1 should be excluded
    let content = await proto1.findContentImpl(proto2.localNode, contentKey)

    check:
      content.isOk()
      content.get().enrs.len() == 1

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer/Accept":
    let (proto1, proto2) = defaultTestSetup(rng)
    let contentKeys = ContentKeysList(@[ContentKeyByteList(@[byte 0x01, 0x02, 0x03])])

    let accept = await proto1.offerImpl(proto2.baseProtocol.localNode, contentKeys)

    check:
      accept.isOk()
      accept.get().connectionId.len == 2
      accept.get().contentKeys.len == contentKeys.len

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer/Accept limit reached for the same content key":
    let (proto1, proto2) = defaultTestSetup(rng)
    let contentKeys = ContentKeysList(@[ContentKeyByteList(@[byte 0x01, 0x02, 0x03])])

    let accept = await proto1.offerImpl(proto2.baseProtocol.localNode, contentKeys)
    let expectedByteList = ContentKeysAcceptList.init(@[Accepted])

    check:
      accept.isOk()
      # Content accepted
      accept.get().contentKeys == expectedByteList

    let accept2 = await proto1.offerImpl(proto2.baseProtocol.localNode, contentKeys)

    check:
      accept2.isOk()
      # Content not accepted
      accept2.get().contentKeys ==
        ContentKeysAcceptList.init(@[DeclinedInboundTransferInProgress])

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer/Accept trigger pruning of timed out offer":
    let (proto1, proto2) = defaultTestSetup(rng)
    let contentKeys = ContentKeysList(@[ContentKeyByteList(@[byte 0x01, 0x02, 0x03])])

    let accept = await proto1.offerImpl(proto2.baseProtocol.localNode, contentKeys)
    let expectedByteList = ContentKeysAcceptList.init(@[Accepted])

    check:
      accept.isOk()
      # Content accepted
      accept.get().contentKeys == expectedByteList

    await sleepAsync(connectionTimeoutTest)

    let accept2 = await proto1.offerImpl(proto2.baseProtocol.localNode, contentKeys)
    check:
      accept2.isOk()
      # Content accepted because previous offer was pruned
      accept2.get().contentKeys == expectedByteList

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer/Accept/Stream":
    let (proto1, proto2) = defaultTestSetup(rng)
    var content: seq[ContentKV]
    for i in 0 ..< contentKeysLimit:
      let contentKV = ContentKV(
        contentKey: ContentKeyByteList(@[byte i]), content: repeat(byte i, 5000)
      )
      content.add(contentKV)

    let res = await proto1.offer(proto2.baseProtocol.localNode, content)

    check res.isOk()

    let (_, contentKeys, contentItems) = await proto2.stream.contentQueue.popFirst()

    check contentItems.len() == content.len()

    for i, contentItem in contentItems:
      let contentKV = content[i]
      check:
        contentItem == contentKV.content
        contentKeys[i] == contentKV.contentKey

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Neighborhood gossip - single content key, value":
    let (proto1, proto2) = defaultTestSetup(rng)

    check proto1.addNode(proto2.localNode) == Added
    let pong = await proto1.ping(proto2.localNode)
    check pong.isOk()

    let
      contentKeys = ContentKeysList(@[ContentKeyByteList(@[byte 0x01, 0x02, 0x03])])
      content: seq[seq[byte]] = @[@[byte 0x04, 0x05, 0x06]]

    block:
      let gossipMetadata =
        await proto1.neighborhoodGossip(Opt.none(NodeId), contentKeys, content)
      check:
        gossipMetadata.successCount == 1
        gossipMetadata.acceptedCount == 1
        gossipMetadata.genericDeclineCount == 0
        gossipMetadata.alreadyStoredCount == 0
        gossipMetadata.notWithinRadiusCount == 0
        gossipMetadata.rateLimitedCount == 0
        gossipMetadata.transferInProgressCount == 0

    let (srcNodeId, keys, items) = await proto2.stream.contentQueue.popFirst()
    check:
      srcNodeId.get() == proto1.localNode.id
      keys.len() == items.len()
      keys.len() == 1
      keys == contentKeys
      items == content

    # Store the content
    proto2.storeContent(keys[0], keys[0].toContentId().get(), items[0])

    # Gossip the same content a second time
    block:
      let gossipMetadata =
        await proto1.neighborhoodGossip(Opt.none(NodeId), contentKeys, content)
      check:
        gossipMetadata.successCount == 1
        gossipMetadata.acceptedCount == 0
        gossipMetadata.genericDeclineCount == 0
        gossipMetadata.alreadyStoredCount == 1
        gossipMetadata.notWithinRadiusCount == 0
        gossipMetadata.rateLimitedCount == 0
        gossipMetadata.transferInProgressCount == 0

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Random gossip - single content key, value":
    let (proto1, proto2) = defaultTestSetup(rng)

    check proto1.addNode(proto2.localNode) == Added
    let pong = await proto1.ping(proto2.localNode)
    check pong.isOk()

    let
      contentKeys = ContentKeysList(@[ContentKeyByteList(@[byte 0x01, 0x02, 0x03])])
      content: seq[seq[byte]] = @[@[byte 0x04, 0x05, 0x06]]

    block:
      let gossipMetadata =
        await proto1.randomGossip(Opt.none(NodeId), contentKeys, content)
      check:
        gossipMetadata.successCount == 1
        gossipMetadata.acceptedCount == 1
        gossipMetadata.genericDeclineCount == 0
        gossipMetadata.alreadyStoredCount == 0
        gossipMetadata.notWithinRadiusCount == 0
        gossipMetadata.rateLimitedCount == 0
        gossipMetadata.transferInProgressCount == 0

    let (srcNodeId, keys, items) = await proto2.stream.contentQueue.popFirst()
    check:
      srcNodeId.get() == proto1.localNode.id
      keys.len() == items.len()
      keys.len() == 1
      keys == contentKeys
      items == content

    # Store the content
    proto2.storeContent(keys[0], keys[0].toContentId().get(), items[0])

    # Gossip the same content a second time
    block:
      let gossipMetadata =
        await proto1.neighborhoodGossip(Opt.none(NodeId), contentKeys, content)
      check:
        gossipMetadata.successCount == 1
        gossipMetadata.acceptedCount == 0
        gossipMetadata.genericDeclineCount == 0
        gossipMetadata.alreadyStoredCount == 1
        gossipMetadata.notWithinRadiusCount == 0
        gossipMetadata.rateLimitedCount == 0
        gossipMetadata.transferInProgressCount == 0

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Correctly mark node as seen after request":
    let (proto1, proto2) = defaultTestSetup(rng)

    let initialNeighbours = proto1.neighbours(proto1.localNode.id, seenOnly = false)

    check:
      len(initialNeighbours) == 0

    discard proto1.addNode(proto2.localNode)

    let allNeighboursAfterAdd = proto1.neighbours(proto1.localNode.id, seenOnly = false)
    let seenNeighboursAfterAdd = proto1.neighbours(proto1.localNode.id, seenOnly = true)

    check:
      len(allNeighboursAfterAdd) == 1
      len(seenNeighboursAfterAdd) == 0

    let pong = await proto1.ping(proto2.localNode)

    let allNeighboursAfterPing =
      proto1.neighbours(proto1.localNode.id, seenOnly = false)
    let seenNeighboursAfterPing =
      proto1.neighbours(proto1.localNode.id, seenOnly = true)

    check:
      pong.isOk()
      len(allNeighboursAfterPing) == 1
      len(seenNeighboursAfterPing) == 1

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Lookup nodes":
    let
      node1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))
      node3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20304))

    # Make node1 know about node2, and node2 about node3
    # node1 will then do a lookup for node3
    check node1.addNode(node2.localNode) == Added
    check node2.addNode(node3.localNode) == Added

    check (await node2.ping(node3.localNode)).isOk()

    let lookupResult = await node1.lookup(node3.localNode.id)

    check:
      # Result should contain node3 as it is in the routing table of node2
      lookupResult.contains(node3.localNode)

    await node1.stopPortalProtocol()
    await node2.stopPortalProtocol()
    await node3.stopPortalProtocol()

  asyncTest "Lookup content - nodes interested":
    let
      node1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))
      node3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20304))

      content = @[byte 1, 2]
      contentList = List[byte, 2048].init(content)
      contentId = readUintBE[256](sha256.digest(content).data)

    # Store the content on node3
    node3.storeContent(contentList, contentId, content)

    # Make node1 know about node2, and node2 about node3
    check node1.addNode(node2.localNode) == Added
    check node2.addNode(node3.localNode) == Added

    # node1 needs to know the radius of the nodes to determine if they are
    # interested in content, so a ping is done.
    check (await node1.ping(node2.localNode)).isOk()
    check (await node2.ping(node3.localNode)).isOk()

    let lookupResult = await node1.contentLookup(contentList, contentId)

    check:
      lookupResult.isSome()

    let res = lookupResult.unsafeGet()

    check:
      res.content == content
      res.nodesInterestedInContent.contains(node2.localNode)

    await node1.stopPortalProtocol()
    await node2.stopPortalProtocol()
    await node3.stopPortalProtocol()

  asyncTest "Valid Bootstrap Node":
    let
      node1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initPortalProtocol(
        rng,
        PrivateKey.random(rng[]),
        localAddress(20303),
        bootstrapRecords = [node1.localNode.record],
      )

    node1.start()
    node2.start()

    check node2.neighbours(node2.localNode.id).len == 1

    await node1.stopPortalProtocol()
    await node2.stopPortalProtocol()

  asyncTest "Invalid Bootstrap Node":
    let
      node1 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initPortalProtocol(
        rng,
        PrivateKey.random(rng[]),
        localAddress(20303),
        bootstrapRecords = [node1.localNode.record],
      )

    # seedTable to add node1 to the routing table
    node2.seedTable()
    check node2.neighbours(node2.localNode.id).len == 1

    # This should fail and drop node1 from the routing table
    await node2.revalidateNode(node1.localNode)

    check node2.neighbours(node2.localNode.id).len == 0

    await node1.closeWait()
    await node2.stopPortalProtocol()

  asyncTest "Adjusting radius after hitting full database":
    # TODO: This test is extremely breakable when changing
    # `contentDeletionFraction` and/or the used test values.
    # Need to rework either this test, or the pruning mechanism, or probably
    # both.
    let
      node1 = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(20303))

      dbLimit = 400_000'u32
      db = ContentDB.new(
        "", dbLimit, RadiusConfig(kind: Dynamic), node1.localNode.id, inMemory = true
      )
      m = StreamManager.new(node1)
      q = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)
      stream = m.registerNewStream(q)

      proto1 = PortalProtocol.new(
        node1,
        protocolId,
        toContentId,
        createGetHandler(db),
        createStoreHandler(db, defaultRadiusConfig),
        createContainsHandler(db),
        createRadiusHandler(db),
        stream,
      )

    let item = genByteSeq(10_000)
    var distances: seq[UInt256] = @[]

    for i in 0 ..< 40:
      proto1.storeContent(
        ByteList[2048].init(@[uint8(i)]), u256(i), item, cacheOffer = true
      )
      distances.add(u256(i) xor proto1.localNode.id)

    distances.sort(order = SortOrder.Descending)

    # With the selected db limit of 100_000 bytes and added elements of 10_000
    # bytes each, the two furthest elements should be prined, i.e index 0 and 1.
    # Index 2 should be still be in database and its distance should be <=
    # updated radius
    check:
      not db.contains((distances[0] xor proto1.localNode.id))
      not db.contains((distances[1] xor proto1.localNode.id))
      not db.contains((distances[2] xor proto1.localNode.id))
      db.contains((distances[3] xor proto1.localNode.id))
      # The radius has been updated and is lower than the maximum start value.
      proto1.dataRadius() < UInt256.high
      # Yet higher than or equal to the furthest non deleted element.
      proto1.dataRadius() >= distances[3]

    await proto1.stop()
    await node1.closeWait()

  asyncTest "Local content - Content cache enabled":
    let (proto1, proto2) = defaultTestSetup(rng)

    # proto1 has no radius so the content won't be stored in the local db
    proto1.dataRadius = proc(): UInt256 =
      0.u256

    let
      contentKey = ContentKeyByteList(@[byte 0x01, 0x02, 0x03])
      contentId = contentKey.toContentId().get()
      content = @[byte 0x04, 0x05, 0x06]

    check:
      proto1.storeContent(contentKey, contentId, content) == false
      proto2.storeContent(contentKey, contentId, content) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.storeContent(contentKey, contentId, content, cacheContent = false) == false
      proto2.storeContent(contentKey, contentId, content, cacheContent = false) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.storeContent(contentKey, contentId, content, cacheContent = true) == false
      proto2.storeContent(contentKey, contentId, content, cacheContent = true) == true

      proto1.getLocalContent(contentKey, contentId).get() == content
      proto2.getLocalContent(contentKey, contentId).get() == content

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Local content - Content cache disabled":
    let (proto1, proto2) = defaultTestSetup(rng)
    proto1.config.disableContentCache = true
    proto2.config.disableContentCache = true

    # proto1 has no radius so the content won't be stored in the local db
    proto1.dataRadius = proc(): UInt256 =
      0.u256

    let
      contentKey = ContentKeyByteList(@[byte 0x01, 0x02, 0x03])
      contentId = contentKey.toContentId().get()
      content = @[byte 0x04, 0x05, 0x06]

    check:
      proto1.storeContent(contentKey, contentId, content) == false
      proto2.storeContent(contentKey, contentId, content) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.storeContent(contentKey, contentId, content, cacheContent = false) == false
      proto2.storeContent(contentKey, contentId, content, cacheContent = false) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.storeContent(contentKey, contentId, content, cacheContent = true) == false
      proto2.storeContent(contentKey, contentId, content, cacheContent = true) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer cache enabled":
    let (proto1, proto2) = defaultTestSetup(rng)

    # proto1 has no radius so the content won't be stored in the local db
    proto1.dataRadius = proc(): UInt256 =
      0.u256

    let
      contentKey = ContentKeyByteList(@[byte 0x01, 0x02, 0x03])
      contentId = contentKey.toContentId().get()
      content = @[byte 0x04, 0x05, 0x06]

    check:
      proto1.storeContent(contentKey, contentId, content, cacheOffer = true) == false
      proto2.storeContent(contentKey, contentId, content, cacheOffer = true) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.offerCache.contains(contentId) == false
      proto2.offerCache.contains(contentId) == true
      proto1.offerCache.len() == 0
      proto2.offerCache.len() == 1

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Offer cache disabled":
    let (proto1, proto2) = defaultTestSetup(rng)
    proto1.config.disableOfferCache = true
    proto2.config.disableOfferCache = true

    # proto1 has no radius so the content won't be stored in the local db
    proto1.dataRadius = proc(): UInt256 =
      0.u256

    let
      contentKey = ContentKeyByteList(@[byte 0x01, 0x02, 0x03])
      contentId = contentKey.toContentId().get()
      content = @[byte 0x04, 0x05, 0x06]

    check:
      proto1.storeContent(contentKey, contentId, content, cacheOffer = true) == false
      proto2.storeContent(contentKey, contentId, content, cacheOffer = true) == true

      proto1.getLocalContent(contentKey, contentId).isNone()
      proto2.getLocalContent(contentKey, contentId).get() == content

      proto1.offerCache.contains(contentId) == false
      proto2.offerCache.contains(contentId) == false
      proto1.offerCache.len() == 0
      proto2.offerCache.len() == 0

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Banned nodes are removed and cannot be added":
    let (proto1, proto2) = defaultTestSetup(rng)

    # add the node
    check:
      proto1.addNode(proto2.localNode) == Added
      proto1.getNode(proto2.localNode.id).isSome()

    # banning the node should remove it from the routing table
    proto1.banNode(proto2.localNode.id, 1.minutes)
    check proto1.getNode(proto2.localNode.id).isNone()

    # cannot add a banned node
    check:
      proto1.addNode(proto2.localNode) == Banned
      proto1.getNode(proto2.localNode.id).isNone()

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Banned nodes are filtered out in FindNodes/Nodes":
    let
      proto1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      proto2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))
      proto3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20304))
      distance = logDistance(proto2.localNode.id, proto3.localNode.id)

    check proto2.addNode(proto3.localNode) == Added
    check (await proto2.ping(proto3.localNode)).isOk()
    check (await proto3.ping(proto2.localNode)).isOk()

    # before banning the node it is returned in the response
    block:
      let res = await proto1.findNodes(proto2.localNode, @[distance])
      check:
        res.isOk()
        res.get().len() == 1

    proto1.banNode(proto3.localNode.id, 1.minutes)

    # after banning the node, it is not returned in the response
    block:
      let res = await proto1.findNodes(proto2.localNode, @[distance])
      check:
        res.isOk()
        res.get().len() == 0

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()
    await proto3.stopPortalProtocol()

  asyncTest "Banned nodes are filtered out in FindContent/Content - send enrs":
    let
      proto1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      proto2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))
      proto3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20304))

    check proto2.addNode(proto3.localNode) == Added
    check (await proto2.ping(proto3.localNode)).isOk()
    check (await proto3.ping(proto2.localNode)).isOk()

    let contentKey = ContentKeyByteList.init(@[1'u8])

    block:
      let res = await proto1.findContent(proto2.localNode, contentKey)
      check:
        res.isOk()
        res.get().nodes.len() == 1

    proto1.banNode(proto3.localNode.id, 1.minutes)

    block:
      let res = await proto1.findContent(proto2.localNode, contentKey)
      check:
        res.isOk()
        res.get().nodes.len() == 0

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()
    await proto3.stopPortalProtocol()

  asyncTest "Drop messages from banned nodes":
    let
      proto1 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20302))
      proto2 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20303))
      proto3 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20304))
      proto4 = initPortalProtocol(rng, PrivateKey.random(rng[]), localAddress(20305))
      contentKey = ContentKeyByteList.init(@[1'u8])

    proto2.banNode(proto1.localNode.id, 1.minutes)
    proto3.banNode(proto1.localNode.id, 1.minutes)
    proto4.banNode(proto1.localNode.id, 1.minutes)

    check:
      (await proto1.ping(proto2.localNode)).error() ==
        "No message data, peer might not support this talk protocol"
      (await proto1.findNodes(proto3.localNode, @[0.uint16])).error() ==
        "No message data, peer might not support this talk protocol"
      (await proto1.findContent(proto4.localNode, contentKey)).error() ==
        "No message data, peer might not support this talk protocol"

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()

  asyncTest "Cannot send message to banned nodes":
    let
      (proto1, proto2) = defaultTestSetup(rng)
      contentKey = ContentKeyByteList.init(@[1'u8])

    check:
      (await proto1.ping(proto2.localNode)).isOk()
      (await proto1.findNodes(proto2.localNode, @[0.uint16])).isOk()
      (await proto1.findContent(proto2.localNode, contentKey)).isOk()

    proto1.banNode(proto2.localNode.id, 1.minutes)

    check:
      (await proto1.ping(proto2.localNode)).error() == "destination node is banned"
      (await proto1.findNodes(proto2.localNode, @[0.uint16])).error() ==
        "destination node is banned"
      (await proto1.findContent(proto2.localNode, contentKey)).error() ==
        "destination node is banned"

    await proto1.stopPortalProtocol()
    await proto2.stopPortalProtocol()
