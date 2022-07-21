# Nimbus - Portal Network
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Implementation of the Portal wire protocol as specified at:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md

{.push raises: [Defect].}

import
  std/[sequtils, sets, algorithm],
  stew/[results, byteutils, leb128], chronicles, chronos, nimcrypto/hash,
  bearssl, ssz_serialization, metrics, faststreams,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2,
    nodes_verification, lru],
  ".."/../[content_db, seed_db],
  "."/[portal_stream, portal_protocol_config],
  ./messages

export messages, routing_table

declareCounter portal_message_requests_incoming,
  "Portal wire protocol incoming message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_decoding_failures,
  "Portal wire protocol message decoding failures",
  labels = ["protocol_id"]
declareCounter portal_message_requests_outgoing,
  "Portal wire protocol outgoing message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_response_incoming,
  "Portal wire protocol incoming message responses",
  labels = ["protocol_id", "message_type"]

const requestBuckets = [1.0, 3.0, 5.0, 7.0, 9.0, Inf]
declareHistogram portal_lookup_node_requests,
  "Portal wire protocol amount of requests per node lookup",
  labels = ["protocol_id"], buckets = requestBuckets
declareHistogram portal_lookup_content_requests,
  "Portal wire protocol amount of requests per node lookup",
  labels = ["protocol_id"], buckets = requestBuckets
declareCounter portal_lookup_content_failures,
  "Portal wire protocol content lookup failures",
  labels = ["protocol_id"]

const contentKeysBuckets = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, Inf]
declareHistogram portal_content_keys_offered,
  "Portal wire protocol amount of content keys per offer message send",
  labels = ["protocol_id"], buckets = contentKeysBuckets
declareHistogram portal_content_keys_accepted,
  "Portal wire protocol amount of content keys per accept message received",
  labels = ["protocol_id"], buckets = contentKeysBuckets
declareCounter portal_gossip_offers_successful,
  "Portal wire protocol successful content offers from neighborhood gossip",
  labels = ["protocol_id"]
declareCounter portal_gossip_offers_failed,
  "Portal wire protocol failed content offers from neighborhood gossip",
  labels = ["protocol_id"]
declareCounter portal_gossip_with_lookup,
  "Portal wire protocol neighborhood gossip that required a node lookup",
  labels = ["protocol_id"]
declareCounter portal_gossip_without_lookup,
  "Portal wire protocol neighborhood gossip that did not require a node lookup",
  labels = ["protocol_id"]


# Note: These metrics are to get some idea on how many enrs are send on average.
# Relevant issue: https://github.com/ethereum/portal-network-specs/issues/136
const enrsBuckets = [0.0, 1.0, 3.0, 5.0, 8.0, 9.0, Inf]
declareHistogram portal_nodes_enrs_packed,
  "Portal wire protocol amount of enrs packed in a nodes message",
  labels = ["protocol_id"], buckets = enrsBuckets
# This one will currently hit the max numbers because all neighbours are send,
# not only the ones closer to the content.
declareHistogram portal_content_enrs_packed,
  "Portal wire protocol amount of enrs packed in a content message",
  labels = ["protocol_id"], buckets = enrsBuckets

declareCounter portal_pruning_counter,
  "Number of pruning event which happened during node lifetime",
  labels = ["protocol_id"]

declareGauge portal_pruning_deleted_elements,
  "Number of elements delted in last pruning",
  labels = ["protocol_id"]

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

  # TalkResp message is a response message so the session is established and a
  # regular discv5 packet is assumed for size calculation.
  # Regular message = IV + header + message
  # talkResp message = rlp: [request-id, response]
  talkRespOverhead =
    16 + # IV size
    55 + # header size
    1 + # talkResp msg id
    3 + # rlp encoding outer list, max length will be encoded in 2 bytes
    9 + # request id (max = 8) + 1 byte from rlp encoding byte string
    3 + # rlp encoding response byte string, max length in 2 bytes
    16 # HMAC

  # These are the concurrent offers per Portal wire protocol that is running.
  # Using the `offerQueue` allows for limiting the amount of offers send and
  # thus how many streams can be started.
  # TODO:
  # More thought needs to go into this as it is currently on a per network
  # basis. Keep it simple like that? Or limit it better at the stream transport
  # level? In the latter case, this might still need to be checked/blocked at
  # the very start of sending the offer, because blocking/waiting too long
  # between the received accept message and actually starting the stream and
  # sending data could give issues due to timeouts on the other side.
  # And then there are still limits to be applied also for FindContent and the
  # incoming directions.
  concurrentOffers = 50

type
  ToContentIdHandler* =
    proc(contentKey: ByteList): Option[ContentId] {.raises: [Defect], gcsafe.}

  PortalProtocolId* = array[2, byte]

  RadiusCache* = LRUCache[NodeId, UInt256]

  ContentInfo* = object
    contentKey*: ByteList
    content*: seq[byte]

  OfferRequestType = enum
    Direct, Database

  OfferRequest = object
    dst: Node
    case kind: OfferRequestType
    of Direct:
      contentList: List[ContentInfo, contentKeysLimit]
    of Database:
      contentKeys: ContentKeysList

  PortalProtocol* = ref object of TalkProtocol
    protocolId*: PortalProtocolId
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    contentDB*: ContentDB
    toContentId*: ToContentIdHandler
    radiusConfig: RadiusConfig
    dataRadius*: UInt256
    bootstrapRecords*: seq[Record]
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]
    stream*: PortalStream
    radiusCache: RadiusCache
    offerQueue: AsyncQueue[OfferRequest]
    offerWorkers: seq[Future[void]]

  PortalResult*[T] = Result[T, cstring]

  FoundContentKind* = enum
    Nodes,
    Content

  FoundContent* = object
    src*: Node
    case kind*: FoundContentKind
    of Content:
      content*: seq[byte]
    of Nodes:
      nodes*: seq[Node]

  ContentLookupResult* = object
    content*: seq[byte]
    # List of nodes which do not have requested content, and for which
    # content is in their range
    nodesInterestedInContent*: seq[Node]

proc init*(
  T: type ContentInfo,
  contentKey: ByteList,
  content: seq[byte]): T =
  ContentInfo(
    contentKey: contentKey,
    content: content
  )

proc init*(
  T: type ContentLookupResult,
  content: seq[byte],
  nodesInterestedInContent: seq[Node]): T =
  ContentLookupResult(
    content: content,
    nodesInterestedInContent: nodesInterestedInContent
  )

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

proc inRange(
  p: PortalProtocol,
  nodeId: NodeId,
  nodeRadius: Uint256,
  contentId: ContentId): bool =
  let distance = p.routingTable.distance(nodeId, contentId)
  distance <= nodeRadius

func inRange*(p: PortalProtocol, contentId: ContentId): bool =
  p.inRange(p.localNode.id, p.dataRadius, contentId)

func truncateEnrs(
    nodes: seq[Node], maxSize: int, enrOverhead: int): List[ByteList, 32] =
  var enrs: List[ByteList, 32]
  var totalSize = 0
  for n in nodes:
    let enr = ByteList.init(n.record.raw)
    if totalSize + enr.len() + enrOverhead <= maxSize:
      let res = enrs.add(enr) # 32 limit will not be reached
      totalSize = totalSize + enr.len()
    else:
      break

  enrs

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

proc handleFindNodes(p: PortalProtocol, fn: FindNodesMessage): seq[byte] =
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

      # TODO: Total amount of messages is set fixed to 1 for now, else we would
      # need to either move the send of the talkresp messages here, or allow for
      # returning multiple messages.
      # On the long run, it might just be better to use a stream in these cases?
      # Size calculation is done to truncate the ENR results in order to not go
      # over the discv5 packet size limits. ENRs are sorted so the closest nodes
      # will still be passed.
      const
        nodesOverhead = 1 + 1 + 4 # msg id + total + container offset
        maxPayloadSize = maxDiscv5PacketSize - talkRespOverhead - nodesOverhead
        enrOverhead = 4 # per added ENR, 4 bytes offset overhead

      let enrs = truncateEnrs(nodes, maxPayloadSize, enrOverhead)
      portal_nodes_enrs_packed.observe(enrs.len().int64)

      encodeMessage(NodesMessage(total: 1, enrs: enrs))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList, 32](@[])
      encodeMessage(NodesMessage(total: 1, enrs: enrs))

proc handleFindContent(
    p: PortalProtocol, fc: FindContentMessage, srcId: NodeId): seq[byte] =
  let contentIdOpt = p.toContentId(fc.contentKey)
  if contentIdOpt.isSome():
    const
      contentOverhead = 1 + 1 # msg id + SSZ Union selector
      maxPayloadSize = maxDiscv5PacketSize - talkRespOverhead - contentOverhead
      enrOverhead = 4 # per added ENR, 4 bytes offset overhead

    let
      contentId = contentIdOpt.get()
      # TODO: Should we first do a simple check on ContentId versus Radius
      # before accessing the database?
      maybeContent = p.contentDB.get(contentId)
    if maybeContent.isSome():
      let content = maybeContent.get()
      if content.len <= maxPayloadSize:
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
        enrs = truncateEnrs(closestNodes, maxPayloadSize, enrOverhead)
      portal_content_enrs_packed.observe(enrs.len().int64)

      encodeMessage(ContentMessage(contentMessageType: enrsType, enrs: enrs))
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

    portal_message_requests_incoming.inc(
      labelValues = [$p.protocolId, $message.kind])

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
    portal_message_decoding_failures.inc(labelValues = [$p.protocolId])
    debug "Packet decoding error", error = decoded.error, srcId, srcUdpAddress
    @[]

proc fromLogRadius(T: type UInt256, logRadius: uint16): T =
  # Get the max value of the logRadius range
  pow((2).stuint(256), logRadius) - 1

proc getInitialRadius(rc: RadiusConfig): UInt256 =
  case rc.kind
  of Static:
    return UInt256.fromLogRadius(rc.logRadius)
  of Dynamic:
    # In case of a dynamic radius we start from the maximum value to quickly
    # gather as much data as possible, and also make sure each data piece in
    # the database is in our range after a node restart.
    # Alternative would be to store node the radius in database, and initialize it
    # from database after a restart
    return UInt256.high()

proc new*(T: type PortalProtocol,
    baseProtocol: protocol.Protocol,
    protocolId: PortalProtocolId,
    contentDB: ContentDB,
    toContentId: ToContentIdHandler,
    bootstrapRecords: openArray[Record] = [],
    distanceCalculator: DistanceCalculator = XorDistanceCalculator,
    config: PortalProtocolConfig = defaultPortalProtocolConfig
    ): T =

  let initialRadius: UInt256 = config.radiusConfig.getInitialRadius()

  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    protocolId: protocolId,
    routingTable: RoutingTable.init(
      baseProtocol.localNode, config.bitsPerHop, config.tableIpLimits,
      baseProtocol.rng, distanceCalculator),
    baseProtocol: baseProtocol,
    contentDB: contentDB,
    toContentId: toContentId,
    radiusConfig: config.radiusConfig,
    dataRadius: initialRadius,
    bootstrapRecords: @bootstrapRecords,
    radiusCache: RadiusCache.init(256),
    offerQueue: newAsyncQueue[OfferRequest](concurrentOffers))

  proto.baseProtocol.registerTalkProtocol(@(proto.protocolId), proto).expect(
    "Only one protocol should have this id")

  let stream = PortalStream.new(udata = proto, rng = proto.baseProtocol.rng)

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
  portal_message_requests_outgoing.inc(
    labelValues = [$p.protocolId, $messageKind(Request)])

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
    portal_message_response_incoming.inc(
      labelValues = [$p.protocolId, $messageKind(Response)])

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

      let connFuture = p.stream.connectTo(
          nodeAddress.unsafeGet(),
          uint16.fromBytesBE(m.connectionId)
        )

      yield connFuture

      var connectionResult: Result[UtpSocket[NodeAddress], string]

      if connFuture.completed():
        connectionResult = connFuture.read()
      else:
        raise connFuture.error

      if connectionResult.isErr():
        debug "Utp connection error while trying to find content",
          error = connectionResult.error
        return err("Error connecting uTP socket")

      let socket = connectionResult.get()

      try:
        # Read all bytes from the socket
        # This will either end with a FIN, or because the read action times out.
        # A FIN does not necessarily mean that the data read is complete. Further
        # validation is required, using a length prefix here might be beneficial for
        # this.
        let readFut = socket.read()

        readFut.cancelCallback = proc(udate: pointer) {.gcsafe.} =
          debug "Socket read cancelled",
            socketKey = socket.socketKey
          # In case this `findContent` gets cancelled while reading the data,
          # send a FIN and clean up the socket.
          socket.close()

        if await readFut.withTimeout(p.stream.contentReadTimeout):
          let content = readFut.read
          # socket received remote FIN and drained whole buffer, it can be
          # safely destroyed without notifing remote
          debug "Socket read fully",
            socketKey = socket.socketKey
          socket.destroy()
          return ok(FoundContent(src: dst, kind: Content, content: content))
        else :
          debug "Socket read time-out",
            socketKey = socket.socketKey
          socket.close()
          return err("Reading data from socket timed out, content request failed")
      except CancelledError as exc:
        # even though we already installed cancelCallback on readFut, it is worth
        # catching CancelledError in case that withTimeout throws CancelledError
        # but readFut have already finished.
        debug "Socket read cancelled",
          socketKey = socket.socketKey

        socket.close()
        raise exc
    of contentType:
      return ok(FoundContent(src: dst, kind: Content, content: m.content.asSeq()))
    of enrsType:
      let records = recordsFromBytes(m.enrs)
      if records.isOk():
        let verifiedNodes =
          verifyNodesRecords(records.get(), dst, enrsResultLimit)

        return ok(FoundContent(src: dst, kind: Nodes, nodes: verifiedNodes))
      else:
        return err("Content message returned invalid ENRs")

proc getContentKeys(o: OfferRequest): ContentKeysList =
  case o.kind
  of Direct:
    var contentKeys:ContentKeysList
    for info in o.contentList:
      discard contentKeys.add(info.contentKey)
    return contentKeys
  of Database:
    return o.contentKeys

proc offer(p: PortalProtocol, o: OfferRequest):
  Future[PortalResult[void]] {.async.} =
  ## Offer triggers offer-accept interaction with one peer
  ## Whole flow has two phases:
  ## 1. Come to an agreement on what content to transfer, by using offer and accept
  ## messages.
  ## 2. Open uTP stream from content provider to content receiver and transfer
  ## agreed content.
  ## There are two types of possible offer requests:
  ## Direct - when caller provides content to transfer. This way, content is
  ## guaranteed to be transferred as it stays in memory until whole transfer
  ## is completed.
  ## Database - when caller provides keys of content to be transferred. This
  ## way content is provided from database just before it is transferred through
  ## uTP socket. This is useful when there is a lot of content to be transferred
  ## to many peers, and keeping it all in memory could exhaust node resources.
  ## Main drawback is that content may be deleted from the node database
  ## by the cleanup process before it will be transferred, so this way does not
  ## guarantee content transfer.
  let contentKeys = getContentKeys(o)
  portal_content_keys_offered.observe(contentKeys.len().int64)

  let acceptMessageResponse = await p.offerImpl(o.dst, contentKeys)

  if acceptMessageResponse.isOk():
    let m = acceptMessageResponse.get()

    let contentKeysLen =
      case o.kind
      of Direct:
        o.contentList.len()
      of Database:
        o.contentKeys.len()

    if m.contentKeys.len() != contentKeysLen:
      # TODO:
      # When there is such system, the peer should get scored negatively here.
      error "Accepted content key bitlist has invalid size"
      return err("Accepted content key bitlist has invalid size")

    let acceptedKeysAmount = m.contentKeys.countOnes()
    portal_content_keys_accepted.observe(acceptedKeysAmount.int64)
    if acceptedKeysAmount == 0:
      # Don't open an uTP stream if no content was requested
      return ok()

    let nodeAddress = NodeAddress.init(o.dst)
    if nodeAddress.isNone():
      # It should not happen as we are already after succesfull talkreq/talkresp
      # cycle
      error "Trying to connect to node with unknown address",
        id = o.dst.id
      return err("Trying to connect to node with unknown address")

    let connectionResult =
      await p.stream.connectTo(
        nodeAddress.unsafeGet(),
        uint16.fromBytesBE(m.connectionId)
      )

    if connectionResult.isErr():
      debug "Utp connection error while trying to offer content",
        error = connectionResult.error
      return err("Error connecting uTP socket")

    let socket = connectionResult.get()

    template lenu32(x: untyped): untyped =
      uint32(len(x))

    case o.kind
    of Direct:
      for i, b in m.contentKeys:
        if b:
          let content = o.contentList[i].content
          var output = memoryOutput()

          output.write(toBytes(content.lenu32, Leb128).toOpenArray())
          output.write(content)

          let dataWritten = await socket.write(output.getOutput)
          if dataWritten.isErr:
            debug "Error writing requested data", error = dataWritten.error
            # No point in trying to continue writing data
            socket.close()
            return err("Error writing requested data")
    of Database:
      for i, b in m.contentKeys:
        if b:
          let contentIdOpt = p.toContentId(o.contentKeys[i])
          if contentIdOpt.isSome():
            let
              contentId = contentIdOpt.get()
              maybeContent = p.contentDB.get(contentId)

            var output = memoryOutput()
            if maybeContent.isSome():
              let content = maybeContent.get()

              output.write(toBytes(content.lenu32, Leb128).toOpenArray())
              output.write(content)
            else:
              # When data turns out missing, add a 0 size varint
              output.write(toBytes(0'u8, Leb128).toOpenArray())

            let dataWritten = await socket.write(output.getOutput)
            if dataWritten.isErr:
              debug "Error writing requested data", error = dataWritten.error
              # No point in trying to continue writing data
              socket.close()
              return err("Error writing requested data")

    await socket.closeWait()
    return ok()
  else:
    return err("No accept response")

proc offer*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[void]] {.async.} =
    let req = OfferRequest(dst: dst, kind: Database, contentKeys: contentKeys)
    let res = await p.offer(req)
    return res

proc offer*(p: PortalProtocol, dst: Node, content: seq[ContentInfo]):
    Future[PortalResult[void]] {.async.} =
    if len(content) > contentKeysLimit:
      return err("Cannot offer more than 64 content items")

    let contentList = List[ContentInfo, contentKeysLimit].init(content)
    let req = OfferRequest(dst: dst, kind: Direct, contentList: contentList)
    let res = await p.offer(req)
    return res

proc offerWorker(p: PortalProtocol) {.async.} =
  while true:
    let req = await p.offerQueue.popFirst()

    let res = await p.offer(req)
    if res.isOk():
      portal_gossip_offers_successful.inc(labelValues = [$p.protocolId])
    else:
      portal_gossip_offers_failed.inc(labelValues = [$p.protocolId])

proc offerQueueEmpty*(p: PortalProtocol): bool =
  p.offerQueue.empty()

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
  var requestAmount = 0'i64

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
        requestAmount.inc()
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

  portal_lookup_node_requests.observe(requestAmount)
  p.lastLookup = now(chronos.Moment)
  return closestNodes

proc triggerPoke*(
    p: PortalProtocol,
    nodes: seq[Node],
    contentKey: ByteList,
    content: seq[byte]) =
  ## Triggers asynchronous offer-accept interaction to provided nodes.
  ## Provided content should be in range of provided nodes.
  for node in nodes:
    if not p.offerQueue.full():
      try:
        let
          ci = ContentInfo(contentKey: contentKey, content: content)
          list = List[ContentInfo, contentKeysLimit].init(@[ci])
          req = OfferRequest(dst: node, kind: Direct, contentList: list)
        p.offerQueue.putNoWait(req)
      except AsyncQueueFullError as e:
        # Should not occur as full() check is done.
        raiseAssert(e.msg)
    else:
      # Offer queue is full, do not start more offer-accept interactions
      return

# TODO ContentLookup and Lookup look almost exactly the same, also lookups in other
# networks will probably be very similar. Extract lookup function to separate module
# and make it more generaic
proc contentLookup*(p: PortalProtocol, target: ByteList, targetId: UInt256):
    Future[Option[ContentLookupResult]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.routingTable.neighbours(
    targetId, BUCKET_SIZE, seenOnly = false)
  # Shuffling the order of the nodes in order to not always hit the same node
  # first for the same request.
  p.baseProtocol.rng[].shuffle(closestNodes)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[PortalResult[FoundContent]]](alpha)
  var requestAmount = 0'i64

  var nodesWithoutContent: seq[Node] = newSeq[Node]()

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.findContent(n, target))
        requestAmount.inc()
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
        let maybeRadius = p.radiusCache.get(content.src.id)
        if maybeRadius.isSome() and
            p.inRange(content.src.id, maybeRadius.unsafeGet(), targetId):
          # Only return nodes which may be interested in content.
          # No need to check for duplicates in nodesWithoutContent
          # as requests are never made two times to the same node.
          nodesWithoutContent.add(content.src)

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
        # cancel any pending queries as the content has been found
        for f in pendingQueries:
          f.cancel()
        portal_lookup_content_requests.observe(requestAmount)
        return some(ContentLookupResult.init(content.content, nodesWithoutContent))
    else:
      # TODO: Should we do something with the node that failed responding our
      # query?
      discard

  portal_lookup_content_failures.inc()
  return none[ContentLookupResult]()

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

proc getNClosestNodesWithRadius*(p: PortalProtocol, n: uint32): seq[(Node, UInt256)] =
  let closestLocalNodes = p.routingTable.neighbours(
    p.localNode.id, k = int(n), seenOnly = true)

  var nodesWithRadiuses: seq[(Node, UInt256)]
  for node in closestLocalNodes:
    let radius = p.radiusCache.get(node.id)
    if radius.isSome():
      nodesWithRadiuses.add((node, radius.unsafeGet()))
  return nodesWithRadiuses

proc neighborhoodGossip*(
    p: PortalProtocol, contentKeys: ContentKeysList, content: seq[seq[byte]])
    {.async.} =
  if content.len() == 0:
    return

  var contentList = List[ContentInfo, contentKeysLimit].init(@[])
  for i, contentItem in content:
    let contentInfo =
      ContentInfo(contentKey: contentKeys[i], content: contentItem)

    discard contentList.add(contentInfo)

  # Just taking the first content item as target id.
  # TODO: come up with something better?
  let contentIdOpt = p.toContentId(contentList[0].contentKey)
  if contentIdOpt.isNone():
    return

  let contentId = contentIdOpt.get()

  # For selecting the closest nodes to whom to gossip the content a mixed
  # approach is taken:
  # 1. Select the closest neighbours in the routing table
  # 2. Check if the radius is known for these these nodes and whether they are
  # in range of the content to be offered.
  # 3. If more than n (= 4) nodes are in range, offer these nodes the content
  # (max nodes set at 8).
  # 4. If less than n nodes are in range, do a node lookup, and offer the nodes
  # returned from the lookup the content (max nodes set at 8)
  #
  # This should give a bigger rate of success and avoid the data being stopped
  # in its propagation than when looking only for nodes in the own routing
  # table, but at the same time avoid unnecessary node lookups.
  # It might still cause issues in data getting propagated in a wider id range.

  const maxGossipNodes = 8

  let closestLocalNodes = p.routingTable.neighbours(
    NodeId(contentId), k = 16, seenOnly = true)

  var gossipNodes: seq[Node]
  for node in closestLocalNodes:
    let radius = p.radiusCache.get(node.id)
    if radius.isSome():
      if p.inRange(node.id, radius.unsafeGet(), contentId):
        gossipNodes.add(node)

  if gossipNodes.len >= 8: # use local nodes for gossip
    portal_gossip_without_lookup.inc(labelValues = [$p.protocolId])
    for node in gossipNodes[0..<min(gossipNodes.len, maxGossipNodes)]:
      let req = OfferRequest(dst: node, kind: Direct, contentList: contentList)
      await p.offerQueue.addLast(req)
  else: # use looked up nodes for gossip
    portal_gossip_with_lookup.inc(labelValues = [$p.protocolId])
    let closestNodes = await p.lookup(NodeId(contentId))

    for node in closestNodes[0..<min(closestNodes.len, maxGossipNodes)]:
      # Note: opportunistically not checking if the radius of the node is known
      # and thus if the node is in radius with the content. Reason is, these
      # should really be the closest nodes in the DHT, and thus are most likely
      # going to be in range of the requested content.
      let req = OfferRequest(dst: node, kind: Direct, contentList: contentList)
      await p.offerQueue.addLast(req)

proc adjustRadius(
    p: PortalProtocol,
    fractionOfDeletedContent: float64,
    furthestElementInDbDistance: UInt256) =

  if fractionOfDeletedContent == 0.0:
    # even though pruning was triggered no content was deleted, it could happen
    # in pathological case of really small database with really big values.
    # log it as error as it should not happenn
    error "Database pruning attempt resulted in no content deleted"
    return

  # we need to invert fraction as our Uin256 implementation does not support
  # multiplication by float
  let invertedFractionAsInt = int64(1.0 / fractionOfDeletedContent)

  let scaledRadius = p.dataRadius div u256(invertedFractionAsInt)

  # Chose larger value to avoid situation, where furthestElementInDbDistance
  # is super close to local id, so local radius would end up too small
  # to accept any more data to local database
  # If scaledRadius radius will be larger it will still contain all elements
  let newRadius = max(scaledRadius, furthestElementInDbDistance)

  debug "Database pruned",
    oldRadius = p.dataRadius,
    newRadius = newRadius,
    furthestDistanceInDb = furthestElementInDbDistance,
    fractionOfDeletedContent = fractionOfDeletedContent

  # both scaledRadius and furthestElementInDbDistance are smaller than current
  # dataRadius, so the radius will constantly decrease through the node
  # life time
  p.dataRadius = newRadius

proc storeContent*(p: PortalProtocol, key: ContentId, content: openArray[byte]) =
  # always re-check that key is in node range, to make sure that invariant that
  # all keys in database are always in node range hold.
  # TODO current silent assumption is that both contentDb and portalProtocol are
  # using the same xor distance function
  if p.inRange(key):
    case p.radiusConfig.kind:
    of Dynamic:
      # In case of dynamic radius setting we obey storage limits and adjust
      # radius to store network fraction corresponding to those storage limits.
      let res = p.contentDB.put(key, content, p.baseProtocol.localNode.id)
      if res.kind == DbPruned:
        portal_pruning_counter.inc(labelValues = [$p.protocolId])
        portal_pruning_deleted_elements.set(
          res.numOfDeletedElements.int64,
          labelValues = [$p.protocolId]
        )

        p.adjustRadius(
          res.fractionOfDeletedContent,
          res.furthestStoredElementDistance
        )
    of Static:
      # If the config is set statically, radius is not adjusted, and is kept
      # constant thorugh node life time, also database max size is disabled
      # so we will effectivly store fraction of the network
      p.contentDB.put(key, content)

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

  for i in 0 ..< concurrentOffers:
    p.offerWorkers.add(offerWorker(p))

proc stop*(p: PortalProtocol) =
  if not p.revalidateLoop.isNil:
    p.revalidateLoop.cancel()
  if not p.refreshLoop.isNil:
    p.refreshLoop.cancel()

  for worker in p.offerWorkers:
    worker.cancel()
  p.offerWorkers = @[]

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

proc resolveWithRadius*(p: PortalProtocol, id: NodeId): Future[Option[(Node, UInt256)]] {.async.} =
  ## Resolve a `Node` based on provided `NodeId`, also try to establish what
  ## is known radius of found node.
  ##
  ## This will first look in the own routing table. If the node is known, it
  ## will try to contact if for newer information. If node is not known or it
  ## does not reply, a lookup is done to see if it can find a (newer) record of
  ## the node on the network.
  ##
  ## If node is found, radius will be first checked in radius cache, it radius
  ## is not known node will be pinged to establish what is its current radius
  ##

  let n = await p.resolve(id)

  if n.isNone():
    return none((Node, UInt256))

  let node = n.unsafeGet()

  let r = p.radiusCache.get(id)

  if r.isSome():
    return some((node, r.unsafeGet()))

  let pongResult = await p.ping(node)

  if pongResult.isOk():
    let maybeRadius = p.radiusCache.get(id)

    # After successful ping radius should already be in cache, but for the unlikely
    # case that it is not, check it just to be sure.
    # TODO: rafactor ping to return node radius.
    if maybeRadius.isNone():
      return none((Node, UInt256))

    # If pong is successful, radius of the node should definitly be in local
    # radius cache
    return some((node, maybeRadius.unsafeGet()))
  else:
    return none((Node, UInt256))

proc offerContentInNodeRange*(
    p: PortalProtocol,
    seedDbPath: string,
    nodeId: NodeId,
    max: uint32,
    starting: uint32):  Future[PortalResult[void]] {.async.} =
  ## Offers `max` closest elements starting from `starting` index to peer
  ## with given `nodeId`.
  ## Maximum value of `max` is 64 , as this is limit for single offer.
  ## `starting` argument is needed as seed_db is read only, so if there is
  ## more content in peer range than max, then to offer 64 closest elements
  # it needs to be set to 0. To offer next 64 elements it need to be set to
  # 64 etc.

  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let (dbPath, dbName) = maybePathAndDbName.unsafeGet()

  let maybeNodeAndRadius = await p.resolveWithRadius(nodeId)

  if maybeNodeAndRadius.isNone():
    return err("Could not find node with provided nodeId")

  let
    db = SeedDb.new(path = dbPath, name = dbName)
    (node, radius) = maybeNodeAndRadius.unsafeGet()
    content = db.getContentInRange(node.id, radius, int64(max), int64(starting))

  # We got all we wanted from seed_db, it can be closed now.
  db.close()

  var ci: seq[ContentInfo]

  for cont in content:
    let k = ByteList.init(cont.contentKey)
    let info = ContentInfo(contentKey: k, content: cont.content)
    ci.add(info)

  let offerResult = await p.offer(node, ci)

  # waiting for offer result, by the end of this call remote node should
  # have received offered content
  return offerResult

proc storeContentInNodeRange*(
    p: PortalProtocol,
    seedDbPath: string,
    max: uint32,
    starting: uint32): PortalResult[void] =
  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let (dbPath, dbName) = maybePathAndDbName.unsafeGet()

  let
    localRadius = p.dataRadius
    db = SeedDb.new(path = dbPath, name = dbName)
    localId = p.localNode.id
    contentInRange = db.getContentInRange(localId, localRadius, int64(max), int64(starting))

  db.close()

  for contentData in contentInRange:
    let cid = UInt256.fromBytesBE(contentData.contentId)
    p.storeContent(cid, contentData.content)

  return ok()
