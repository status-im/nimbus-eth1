# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Implementation of the Portal wire protocol as specified at:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md

{.push raises: [Defect].}

import
  std/[sequtils, sets, algorithm],
  stew/[results, byteutils], chronicles, chronos, nimcrypto/hash, bearssl,
  ssz_serialization,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2,
    nodes_verification, lru],
  ../../content_db,
  "."/[portal_stream, portal_protocol_config],
  ./messages

export messages, routing_table

logScope:
  topics = "portal_wire"

const
  alpha = 3 ## Kademlia concurrency factor
  enrsResultLimit* = 32 ## Maximum amount of ENRs in the total Nodes messages
  ## that will be processed
  refreshInterval = 5.minutes ## Interval of launching a random query to
  ## refresh the routing table.
  revalidateMax = 10000 ## Revalidation of a peer is done between 0 and this
  ## value in milliseconds
  initialLookups = 1 ## Amount of lookups done when populating the routing table

type
  ToContentIdHandler* =
    proc(contentKey: ByteList): Option[ContentId] {.raises: [Defect], gcsafe.}

  PortalProtocolId* = array[2, byte]

  RadiusCache* = LRUCache[NodeId, UInt256]

  PortalProtocol* = ref object of TalkProtocol
    protocolId*: PortalProtocolId
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    contentDB*: ContentDB
    toContentId: ToContentIdHandler
    dataRadius*: UInt256
    bootstrapRecords*: seq[Record]
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]
    stream*: PortalStream
    radiusCache: RadiusCache

  PortalResult*[T] = Result[T, cstring]

  FoundContentKind* = enum
    Nodes,
    Content

  FoundContent* = object
    case kind*: FoundContentKind
    of Content:
      content*: seq[byte]
    of Nodes:
      nodes*: seq[Node]

func `$`(id: PortalProtocolId): string =
  id.toHex()

proc addNode*(p: PortalProtocol, node: Node): NodeStatus =
  p.routingTable.addNode(node)

proc addNode*(p: PortalProtocol, r: Record): bool =
  let node = newNode(r)
  if node.isOk():
    p.addNode(node[]) == Added
  else:
    false

func localNode*(p: PortalProtocol): Node = p.baseProtocol.localNode

func neighbours*(p: PortalProtocol, id: NodeId, seenOnly = false): seq[Node] =
  p.routingTable.neighbours(id = id, seenOnly = seenOnly)

func inRange*(p: PortalProtocol, contentId: ContentId): bool =
  let distance = p.routingTable.distance(p.localNode.id, contentId)
  distance <= p.dataRadius

func handlePing(
    p: PortalProtocol, ping: PingMessage, srcId: NodeId): seq[byte] =
  # TODO: This should become custom per Portal Network
  # TODO: Need to think about the effect of malicious actor sending lots of
  # pings from different nodes to clear the LRU.
  let customPayloadDecoded =
    try: SSZ.decode(ping.customPayload.asSeq(), CustomPayload)
    except MalformedSszError, SszSizeMismatchError:
      # invalid custom payload, send empty back
      return @[]
  p.radiusCache.put(srcId, customPayloadDecoded.dataRadius)

  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let p = PongMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  encodeMessage(p)

func handleFindNodes(p: PortalProtocol, fn: FindNodesMessage): seq[byte] =
  if fn.distances.len == 0:
    let enrs = List[ByteList, 32](@[])
    encodeMessage(NodesMessage(total: 1, enrs: enrs))
  elif fn.distances.contains(0):
    # A request for our own record.
    let enr = ByteList(rlp.encode(p.baseProtocol.localNode.record))
    encodeMessage(NodesMessage(total: 1, enrs: List[ByteList, 32](@[enr])))
  else:
    let distances = fn.distances.asSeq()
    if distances.all(proc (x: uint16): bool = return x <= 256):
      let
        nodes = p.routingTable.neighboursAtDistances(distances, seenOnly = true)
        enrs = nodes.map(proc(x: Node): ByteList = ByteList(x.record.raw))

      # TODO: Fixed here to total message of 1 for now, as else we would need to
      # either move the send of the talkresp messages here, or allow for
      # returning multiple messages.
      # On the long run, it might just be better to use a stream in these cases?
      encodeMessage(
        NodesMessage(total: 1, enrs: List[ByteList, 32](List(enrs))))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList, 32](@[])
      encodeMessage(NodesMessage(total: 1, enrs: enrs))

proc handleFindContent(
    p: PortalProtocol, fc: FindContentMessage, srcId: NodeId): seq[byte] =
  let contentIdOpt = p.toContentId(fc.contentKey)
  if contentIdOpt.isSome():
    let
      contentId = contentIdOpt.get()
      # TODO: Should we first do a simple check on ContentId versus Radius
      # before accessing the database?
      maybeContent = p.contentDB.get(contentId)
    if maybeContent.isSome():
      let content = maybeContent.get()
       # TODO: properly calculate max content size
      if content.len <= 1000:
        encodeMessage(ContentMessage(
          contentMessageType: contentType, content: ByteList(content)))
      else:
        let connectionId = p.stream.addContentRequest(srcId, content)

        encodeMessage(ContentMessage(
          contentMessageType: connectionIdType, connectionId: connectionId))
    else:
      # Don't have the content, send closest neighbours to content id.
      let
        closestNodes = p.routingTable.neighbours(
          NodeId(contentId), seenOnly = true)
        enrs =
          closestNodes.map(proc(x: Node): ByteList = ByteList(x.record.raw))
      encodeMessage(ContentMessage(
        contentMessageType: enrsType, enrs: List[ByteList, 32](List(enrs))))
  else:
    # Return empty response when content key validation fails
    # TODO: Better would be to return no message at all, needs changes on
    # discv5 layer.
    @[]

proc handleOffer(p: PortalProtocol, o: OfferMessage, srcId: NodeId): seq[byte] =
  var contentKeysBitList = ContentKeysBitList.init(o.contentKeys.len)
  var contentKeys = ContentKeysList.init(@[])
  # TODO: Do we need some protection against a peer offering lots (64x) of
  # content that fits our Radius but is actually bogus?
  # Additional TODO, but more of a specification clarification: What if we don't
  # want any of the content? Reply with empty bitlist and a connectionId of
  # all zeroes but don't actually allow an uTP connection?
  for i, contentKey in o.contentKeys:
    let contentIdOpt = p.toContentId(contentKey)
    if contentIdOpt.isSome():
      let contentId = contentIdOpt.get()
      if p.inRange(contentId):
        if not p.contentDB.contains(contentId):
          contentKeysBitList.setBit(i)
          discard contentKeys.add(contentKey)
    else:
      # Return empty response when content key validation fails
      return @[]

  let connectionId =
    if contentKeysBitList.countOnes() != 0:
      p.stream.addContentOffer(srcId, contentKeys)
    else:
      # When the node does not accept any of the content offered, reply with an
      # all zeroes bitlist and connectionId.
      # Note: What to do in this scenario is not defined in the Portal spec.
      Bytes2([byte 0x00, 0x00])

  encodeMessage(
    AcceptMessage(connectionId: connectionId, contentKeys: contentKeysBitList))

proc messageHandler(protocol: TalkProtocol, request: seq[byte],
    srcId: NodeId, srcUdpAddress: Address): seq[byte] =
  doAssert(protocol of PortalProtocol)

  logScope:
    protocolId = p.protocolId

  let p = PortalProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message request", srcId, srcUdpAddress, kind = message.kind
    # Received a proper Portal message, check if this node exists in the base
    # routing table and add if so.
    # When the node exists in the base discv5 routing table it is likely that
    # it will/would end up in the portal routing tables too but that is not
    # certain as more nodes might exists on the base layer, and it will depend
    # on the distance, order of lookups, etc.
    # Note: Could add a findNodes with distance 0 call when not, and perhaps,
    # optionally pass ENRs if the message was a discv5 handshake containing the
    # ENR.
    let node = p.baseProtocol.getNode(srcId)
    if node.isSome():
      discard p.routingTable.addNode(node.get())

    case message.kind
    of MessageKind.ping:
      p.handlePing(message.ping, srcId)
    of MessageKind.findnodes:
      p.handleFindNodes(message.findNodes)
    of MessageKind.findcontent:
      p.handleFindContent(message.findcontent, srcId)
    of MessageKind.offer:
      p.handleOffer(message.offer, srcId)
    else:
      # This would mean a that Portal wire response message is being send over a
      # discv5 talkreq message.
      debug "Invalid Portal wire message type over talkreq", kind = message.kind
      @[]
  else:
    debug "Packet decoding error", error = decoded.error, srcId, srcUdpAddress
    @[]

proc processContent(
    stream: PortalStream, contentKeys: ContentKeysList, content: seq[byte])
    {.gcsafe, raises: [Defect].}

proc new*(T: type PortalProtocol,
    baseProtocol: protocol.Protocol,
    protocolId: PortalProtocolId,
    contentDB: ContentDB,
    toContentId: ToContentIdHandler,
    dataRadius = UInt256.high(),
    bootstrapRecords: openArray[Record] = [],
    distanceCalculator: DistanceCalculator = XorDistanceCalculator,
    config: PortalProtocolConfig = defaultPortalProtocolConfig
    ): T =

  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    protocolId: protocolId,
    routingTable: RoutingTable.init(
      baseProtocol.localNode, config.bitsPerHop, config.tableIpLimits,
      baseProtocol.rng, distanceCalculator),
    baseProtocol: baseProtocol,
    contentDB: contentDB,
    toContentId: toContentId,
    dataRadius: dataRadius,
    bootstrapRecords: @bootstrapRecords,
    radiusCache: RadiusCache.init(256))

  proto.baseProtocol.registerTalkProtocol(@(proto.protocolId), proto).expect(
    "Only one protocol should have this id")

  let stream = PortalStream.new(
    processContent, udata = proto, rng = proto.baseProtocol.rng)

  proto.stream = stream

  proto

# Sends the discv5 talkreq nessage with provided Portal message, awaits and
# validates the proper response, and updates the Portal Network routing table.
proc reqResponse[Request: SomeMessage, Response: SomeMessage](
    p: PortalProtocol,
    dst: Node,
    request: Request
    ): Future[PortalResult[Response]] {.async.} =
  logScope:
    protocolId = p.protocolId

  trace "Send message request", dstId = dst.id, kind = messageKind(Request)

  let talkresp =
    await talkreq(p.baseProtocol, dst, @(p.protocolId), encodeMessage(request))

  # Note: Failure of `decodeMessage` might also simply mean that the peer is
  # not supporting the specific talk protocol, as according to specification
  # an empty response needs to be send in that case.
  # See: https://github.com/ethereum/devp2p/blob/master/discv5/discv5-wire.md#talkreq-request-0x05
  let messageResponse = talkresp
    .flatMap(proc (x: seq[byte]): Result[Message, cstring] = decodeMessage(x))
    .flatMap(proc (m: Message): Result[Response, cstring] =
      getInnerMessageResult[Response](
        m, cstring"Invalid message response received")
    )

  if messageResponse.isOk():
    trace "Received message response", srcId = dst.id,
      srcAddress = dst.address, kind = messageKind(Response)
    p.routingTable.setJustSeen(dst)
  else:
    debug "Error receiving message response", error = messageResponse.error,
      srcId = dst.id, srcAddress = dst.address
    p.routingTable.replaceNode(dst)

  return messageResponse

proc pingImpl*(p: PortalProtocol, dst: Node):
    Future[PortalResult[PongMessage]] {.async.} =
  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let ping = PingMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  return await reqResponse[PingMessage, PongMessage](p, dst, ping)

proc findNodesImpl*(p: PortalProtocol, dst: Node, distances: List[uint16, 256]):
    Future[PortalResult[NodesMessage]] {.async.} =
  let fn = FindNodesMessage(distances: distances)

  # TODO Add nodes validation
  return await reqResponse[FindNodesMessage, NodesMessage](p, dst, fn)

proc findContentImpl*(p: PortalProtocol, dst: Node, contentKey: ByteList):
    Future[PortalResult[ContentMessage]] {.async.} =
  let fc = FindContentMessage(contentKey: contentKey)

  return await reqResponse[FindContentMessage, ContentMessage](p, dst, fc)

proc offerImpl*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[AcceptMessage]] {.async.} =
  let offer = OfferMessage(contentKeys: contentKeys)

  return await reqResponse[OfferMessage, AcceptMessage](p, dst, offer)

proc recordsFromBytes*(rawRecords: List[ByteList, 32]): PortalResult[seq[Record]] =
  var records: seq[Record]
  for r in rawRecords.asSeq():
    var record: Record
    if record.fromBytes(r.asSeq()):
      records.add(record)
    else:
      # If any of the ENRs is invalid, fail immediatly. This is similar as what
      # is done on the discovery v5 layer.
      return err("Deserialization of an ENR failed")

  ok(records)

proc ping*(p: PortalProtocol, dst: Node):
    Future[PortalResult[PongMessage]] {.async.} =
  let pongResponse = await p.pingImpl(dst)

  if pongResponse.isOK():
    let pong = pongResponse.get()
    # TODO: This should become custom per Portal Network
    let customPayloadDecoded =
      try: SSZ.decode(pong.customPayload.asSeq(), CustomPayload)
      except MalformedSszError, SszSizeMismatchError:
        # invalid custom payload
        return err("Pong message contains invalid custom payload")

    p.radiusCache.put(dst.id, customPayloadDecoded.dataRadius)

  return pongResponse

proc findNodes*(
    p: PortalProtocol, dst: Node, distances: seq[uint16]):
    Future[PortalResult[seq[Node]]] {.async.} =
  let nodesMessage = await p.findNodesImpl(dst, List[uint16, 256](distances))
  if nodesMessage.isOk():
    let records = recordsFromBytes(nodesMessage.get().enrs)
    if records.isOk():
      # TODO: distance function is wrong here for state, fix + tests
      return ok(verifyNodesRecords(
        records.get(), dst, enrsResultLimit, distances))
    else:
      return err(records.error)
  else:
    return err(nodesMessage.error)

proc findContent*(p: PortalProtocol, dst: Node, contentKey: ByteList):
    Future[PortalResult[FoundContent]] {.async.} =
  let contentMessageResponse = await p.findContentImpl(dst, contentKey)

  if contentMessageResponse.isOk():
    let m = contentMessageResponse.get()
    case m.contentMessageType:
    of connectionIdType:
      # uTP protocol uses BE for all values in the header, incl. connection id
      let nodeAddress = NodeAddress.init(dst)
      if nodeAddress.isNone():
        # It should not happen as we are already after succesfull talkreq/talkresp
        # cycle
        error "Trying to connect to node with unknown address",
          id = dst.id
        return err("Trying to connect to node with unknown address")

      let socketRes = await p.stream.transport.connectTo(
          nodeAddress.unsafeGet(), uint16.fromBytesBE(m.connectionId))
      if socketRes.isErr():
        # TODO: get proper error mapped
        return err("Error connecting to uTP socket")
      let socket = socketRes.get()
      if not socket.isConnected():
        socket.close()
        return err("Portal uTP socket is not in connected state")

      # Read all bytes from the socket
      # This will either end with a FIN, or because the read action times out.
      # A FIN does not necessarily mean that the data read is complete. Further
      # validation is required, using a length prefix here might be beneficial for
      # this.
      let readData = socket.read()
      if await readData.withTimeout(p.stream.readTimeout):
        let content = readData.read
        await socket.destroyWait()
        return ok(FoundContent(kind: Content, content: content))
      else:
        socket.close()
        return err("Reading data from socket timed out, content request failed")
    of contentType:
      return ok(FoundContent(kind: Content, content: m.content.asSeq()))
    of enrsType:
      let records = recordsFromBytes(m.enrs)
      if records.isOk():
        let verifiedNodes =
          verifyNodesRecords(records.get(), dst, enrsResultLimit)

        return ok(FoundContent(kind: Nodes, nodes: verifiedNodes))
      else:
        return err("Content message returned invalid ENRs")

# TODO: Depending on how this gets used, it might be better not to request
# the data from the database here, but pass it as parameter. (like, if it was
# just received it and now needs to be forwarded)
proc offer*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[void]] {.async.} =
  let acceptMessageResponse = await p.offerImpl(dst, contentKeys)

  if acceptMessageResponse.isOk():
    let m = acceptMessageResponse.get()

    # Filter contentKeys with bitlist
    var requestedContentKeys: seq[ByteList]
    for i, b in m.contentKeys:
      if b:
        requestedContentKeys.add(contentKeys[i])

    if requestedContentKeys.len() == 0:
      # Don't open an uTP stream if no content was requested
      return ok()

    let nodeAddress = NodeAddress.init(dst)
    if nodeAddress.isNone():
      # It should not happen as we are already after succesfull talkreq/talkresp
      # cycle
      error "Trying to connect to node with unknown address",
        id = dst.id
      return err("Trying to connect to node with unknown address")

    let clientSocketRes = await p.stream.transport.connectTo(
      nodeAddress.unsafeGet(), uint16.fromBytesBE(m.connectionId))
    if clientSocketRes.isErr():
      # TODO: get proper error mapped
      return err("Error connecting to uTP socket")
    let clientSocket = clientSocketRes.get()
    if not clientSocket.isConnected():
      clientSocket.close()
      return err("Portal uTP socket is not in connected state")

    for contentKey in requestedContentKeys:
      let contentIdOpt = p.toContentId(contentKey)
      if contentIdOpt.isSome():
        let
          contentId = contentIdOpt.get()
          maybeContent = p.contentDB.get(contentId)
        if maybeContent.isSome():
          let content = maybeContent.get()
          let dataWritten = await clientSocket.write(content)
          if dataWritten.isErr:
            error "Error writing requested data", error = dataWritten.error
            # No point in trying to continue writing data
            clientSocket.close()
            return err("Error writing requested data")

    await clientSocket.closeWait()
    return ok()
  else:
    return err("No accept response")

proc neighborhoodGossip*(p: PortalProtocol, contentKeys: ContentKeysList) {.async.} =
  let contentKey = contentKeys[0] # for now only 1 item is considered
  let contentIdOpt = p.toContentId(contentKey)
  if contentIdOpt.isNone():
    return

  let contentId = contentIdOpt.get()
  # gossip content to closest neighbours to target:
  # Selected closest 6 now. Better is perhaps to select 16 closest and then
  # select 6 random out of those.
  # TODO: Might actually have to do here closest to the local node, else data
  # will not propagate well over to nodes with "large" Radius?
  let closestNodes = p.routingTable.neighbours(
    NodeId(contentId), k = 6, seenOnly = false)

  for node in closestNodes:
    # Not doing anything if this fails
    discard await p.offer(node, contentKeys)

proc processContent(
    stream: PortalStream, contentKeys: ContentKeysList, content: seq[byte])
    {.gcsafe, raises: [Defect].} =
  let p = getUserData[PortalProtocol](stream)

  # TODO: validate content
  # - check amount of content items according to ContentKeysList
  # - History Network specific: each content item, if header, check hash:
  #   this part of thevalidation will be specific per network & type and should
  #   be thus be custom per network

  # TODO: for now we only consider 1 item being offered
  if contentKeys.len() == 1:
    let contentKey = contentKeys[0]
    let contentIdOpt = p.toContentId(contentKey)
    if contentIdOpt.isNone():
      return

    let contentId = contentIdOpt.get()
    # Store content, should we recheck radius?
    p.contentDB.put(contentId, content)

    asyncSpawn neighborhoodGossip(p, contentKeys)

proc lookupWorker(
    p: PortalProtocol, dst: Node, target: NodeId): Future[seq[Node]] {.async.} =
  let distances = lookupDistances(target, dst.id)
  let nodesMessage = await p.findNodes(dst, distances)
  if nodesMessage.isOk():
    let nodes = nodesMessage.get()
    # Attempt to add all nodes discovered
    for n in nodes:
      discard p.routingTable.addNode(n)

    return nodes
  else:
    return @[]

proc lookup*(p: PortalProtocol, target: NodeId): Future[seq[Node]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.routingTable.neighbours(target, BUCKET_SIZE,
    seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = query.read
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        # If it wasn't seen before, insert node while remaining sorted
        closestNodes.insert(n, closestNodes.lowerBound(n,
          proc(x: Node, n: Node): int =
            cmp(p.routingTable.distance(x.id, target),
              p.routingTable.distance(n.id, target))
        ))

        if closestNodes.len > BUCKET_SIZE:
          closestNodes.del(closestNodes.high())

  p.lastLookup = now(chronos.Moment)
  return closestNodes

# TODO ContentLookup and Lookup look almost exactly the same, also lookups in other
# networks will probably be very similar. Extract lookup function to separate module
# and make it more generaic
proc contentLookup*(p: PortalProtocol, target: ByteList, targetId: UInt256):
    Future[Option[seq[byte]]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.routingTable.neighbours(targetId, BUCKET_SIZE,
    seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[PortalResult[FoundContent]]](alpha)

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.findContent(n, target))
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let contentResult = query.read

    if contentResult.isOk():
      let content = contentResult.get()

      case content.kind
      of Nodes:
        for n in content.nodes:
          if not seen.containsOrIncl(n.id):
            discard p.routingTable.addNode(n)
            # If it wasn't seen before, insert node while remaining sorted
            closestNodes.insert(n, closestNodes.lowerBound(n,
              proc(x: Node, n: Node): int =
                cmp(p.routingTable.distance(x.id, targetId),
                  p.routingTable.distance(n.id, targetId))
            ))

            if closestNodes.len > BUCKET_SIZE:
              closestNodes.del(closestNodes.high())
      of Content:
        # cancel any pending queries as we have find the content
        for f in pendingQueries:
          f.cancel()

        return some(content.content)
    else:
      # TODO: Should we do something with the node that failed responding our
      # query?
      discard

  return none[seq[byte]]()

proc query*(p: PortalProtocol, target: NodeId, k = BUCKET_SIZE): Future[seq[Node]]
    {.async.} =
  ## Query k nodes for the given target, returns all nodes found, including the
  ## nodes queried.
  ##
  ## This will take k nodes from the routing table closest to target and
  ## query them for nodes closest to target. If there are less than k nodes in
  ## the routing table, nodes returned by the first queries will be used.
  var queryBuffer = p.routingTable.neighbours(target, k, seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in queryBuffer:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)

  while true:
    var i = 0
    while i < min(queryBuffer.len, k) and pendingQueries.len < alpha:
      let n = queryBuffer[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = query.read
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        queryBuffer.add(n)

  p.lastLookup = now(chronos.Moment)
  return queryBuffer

proc queryRandom*(p: PortalProtocol): Future[seq[Node]] =
  ## Perform a query for a random target, return all nodes discovered.
  p.query(NodeId.random(p.baseProtocol.rng[]))

proc seedTable*(p: PortalProtocol) =
  ## Seed the table with specifically provided Portal bootstrap nodes. These are
  ## nodes that must support the wire protocol for the specific content network.
  # Note: We allow replacing the bootstrap nodes in the routing table as it is
  # possible that some of these are not supporting the specific portal network.
  # Other note: One could also pick nodes from the discv5 routing table to
  # bootstrap the portal networks, however it would require a flag in the ENR to
  # be added and there might be none in the routing table due to low amount of
  # Portal nodes versus other nodes.
  logScope:
    protocolId = p.protocolId

  for record in p.bootstrapRecords:
    if p.addNode(record):
      debug "Added bootstrap node", uri = toURI(record),
        protocolId = p.protocolId
    else:
      error "Bootstrap node could not be added", uri = toURI(record),
        protocolId = p.protocolId

proc populateTable(p: PortalProtocol) {.async.} =
  ## Do a set of initial lookups to quickly populate the table.
  # start with a self target query (neighbour nodes)
  logScope:
    protocolId = p.protocolId

  let selfQuery = await p.query(p.baseProtocol.localNode.id)
  trace "Discovered nodes in self target query", nodes = selfQuery.len

  for i in 0..<initialLookups:
    let randomQuery = await p.queryRandom()
    trace "Discovered nodes in random target query", nodes = randomQuery.len

  debug "Total nodes in routing table after populate",
    total = p.routingTable.len()

proc revalidateNode*(p: PortalProtocol, n: Node) {.async.} =
  let pong = await p.ping(n)

  if pong.isOK():
    let res = pong.get()
    if res.enrSeq > n.record.seqNum:
      # Request new ENR
      let nodesMessage = await p.findNodes(n, @[0'u16])
      if nodesMessage.isOk():
        let nodes = nodesMessage.get()
        if nodes.len > 0: # Normally a node should only return 1 record actually
          discard p.routingTable.addNode(nodes[0])

proc revalidateLoop(p: PortalProtocol) {.async.} =
  ## Loop which revalidates the nodes in the routing table by sending the ping
  ## message.
  try:
    while true:
      await sleepAsync(milliseconds(p.baseProtocol.rng[].rand(revalidateMax)))
      let n = p.routingTable.nodeToRevalidate()
      if not n.isNil:
        asyncSpawn p.revalidateNode(n)
  except CancelledError:
    trace "revalidateLoop canceled"

proc refreshLoop(p: PortalProtocol) {.async.} =
  ## Loop that refreshes the routing table by starting a random query in case
  ## no queries were done since `refreshInterval` or more.
  ## It also refreshes the majority address voted for via pong responses.
  logScope:
    protocolId = p.protocolId

  try:
    while true:
      # TODO: It would be nicer and more secure if this was event based and/or
      # steered from the routing table.
      while p.routingTable.len() == 0:
        p.seedTable()
        await p.populateTable()
        await sleepAsync(5.seconds)

      let currentTime = now(chronos.Moment)
      if currentTime > (p.lastLookup + refreshInterval):
        let randomQuery = await p.queryRandom()
        trace "Discovered nodes in random target query", nodes = randomQuery.len
        debug "Total nodes in routing table", total = p.routingTable.len()

      await sleepAsync(refreshInterval)
  except CancelledError:
    trace "refreshLoop canceled"

proc start*(p: PortalProtocol) =
  p.refreshLoop = refreshLoop(p)
  p.revalidateLoop = revalidateLoop(p)

proc stop*(p: PortalProtocol) =
  if not p.revalidateLoop.isNil:
    p.revalidateLoop.cancel()
  if not p.refreshLoop.isNil:
    p.refreshLoop.cancel()

proc resolve*(p: PortalProtocol, id: NodeId): Future[Option[Node]] {.async.} =
  ## Resolve a `Node` based on provided `NodeId`.
  ##
  ## This will first look in the own routing table. If the node is known, it
  ## will try to contact if for newer information. If node is not known or it
  ## does not reply, a lookup is done to see if it can find a (newer) record of
  ## the node on the network.
  if id == p.localNode.id:
    return some(p.localNode)

  let node = p.routingTable.getNode(id)
  if node.isSome():
    let nodesMessage = await p.findNodes(node.get(), @[0'u16])
    # TODO: Handle failures better. E.g. stop on different failures than timeout
    if nodesMessage.isOk() and nodesMessage[].len > 0:
      return some(nodesMessage[][0])

  let discovered = await p.lookup(id)
  for n in discovered:
    if n.id == id:
      if node.isSome() and node.get().record.seqNum >= n.record.seqNum:
        return node
      else:
        return some(n)

  return node
