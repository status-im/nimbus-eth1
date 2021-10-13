# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sequtils, sets, algorithm],
  stew/results, chronicles, chronos, nimcrypto/hash,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2, nodes_verification],
  eth/ssz/ssz_serialization,
  ./messages

export messages, routing_table

logScope:
  topics = "portal_wire"

const
  Alpha = 3 ## Kademlia concurrency factor
  LookupRequestLimit = 3 ## Amount of distances requested in a single Findnode
  ## message for a lookup or query
  EnrsResultLimit = 32 ## Maximum amount of ENRs in the total Nodes messages
  ## that will be processed
  RefreshInterval = 5.minutes ## Interval of launching a random query to
  ## refresh the routing table.
  RevalidateMax = 10000 ## Revalidation of a peer is done between 0 and this
  ## value in milliseconds
  InitialLookups = 1 ## Amount of lookups done when populating the routing table

type
  ContentResultKind* = enum
    ContentFound, ContentMissing, ContentKeyValidationFailure

  ContentResult* = object
    case kind*: ContentResultKind
    of ContentFound:
      content*: seq[byte]
    of ContentMissing:
      contentId*: Uint256
    of ContentKeyValidationFailure:
      error*: string

  # Treating Result as typed union type. If the content is present the handler
  # should return it, if not it should return the content id so that closest
  # neighbours can be localized.
  ContentHandler* =
    proc(contentKey: ByteList): ContentResult {.raises: [Defect], gcsafe.}

  PortalProtocol* = ref object of TalkProtocol
    protocolId: seq[byte]
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    dataRadius*: UInt256
    handleContentRequest: ContentHandler
    bootstrapRecords*: seq[Record]
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]

  PortalResult*[T] = Result[T, cstring]

  LookupResultKind = enum
    Nodes, Content

  LookupResult = object
    case kind: LookupResultKind
    of Nodes:
      nodes: seq[Node]
    of Content:
      content: ByteList

proc addNode*(p: PortalProtocol, node: Node): NodeStatus =
  p.routingTable.addNode(node)

proc addNode*(p: PortalProtocol, r: Record): bool =
  let node = newNode(r)
  if node.isOk():
    p.addNode(node[]) == Added
  else:
    false

func localNode*(p: PortalProtocol): Node = p.baseProtocol.localNode

proc neighbours*(p: PortalProtocol, id: NodeId, seenOnly = false): seq[Node] =
  p.routingTable.neighbours(id = id, seenOnly = seenOnly)

# TODO:
# - On incoming portal ping of unknown node: add node to routing table by
# grabbing ENR from discv5 routing table (might not have it)?
# - ENRs with portal protocol capabilities as field?

proc handlePing(p: PortalProtocol, ping: PingMessage):
    seq[byte] =
  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let p = PongMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  encodeMessage(p)

proc handleFindNode(p: PortalProtocol, fn: FindNodeMessage): seq[byte] =
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

proc handleFindContent(p: PortalProtocol, fc: FindContentMessage): seq[byte] =
  # TODO: Should we first do a simple check on ContentId versus Radius?
  # That would needs access to specific toContentId call, or we need to move it
  # to handleContentRequest, which would need access to the Radius value.
  let contentHandlingResult = p.handleContentRequest(fc.contentKey)
  case contentHandlingResult.kind
  of ContentFound:
    # TODO: Need to provide uTP connectionId when content is too large for a
    # single response.
    let content = contentHandlingResult.content
    let enrs = List[ByteList, 32](@[]) # Empty enrs when payload is send
    encodeMessage(ContentMessage(
      enrs: enrs, content: ByteList(content)))
  of ContentMissing:
    let
      contentId = contentHandlingResult.contentId
      closestNodes = p.routingTable.neighbours(
        NodeId(contentId), seenOnly = true)
      content = ByteList(@[]) # Empty payload when enrs are send
      enrs =
        closestNodes.map(proc(x: Node): ByteList = ByteList(x.record.raw))
    encodeMessage(ContentMessage(
      enrs: List[ByteList, 32](List(enrs)), content: content))

  of ContentKeyValidationFailure:
    # Return empty response when content key validation fails
    let content = ByteList(@[])
    let enrs = List[ByteList, 32](@[]) # Empty enrs when payload is send
    encodeMessage(ContentMessage(
      enrs: enrs, content: content))

proc handleOffer(p: PortalProtocol, a: OfferMessage): seq[byte] =
  let
    # TODO: Random ID that needs to be stored together with some buffer that
    # gets shared with uTP session that needs to be set up (start listening)
    connectionId = Bytes2([byte 0x01, 0x02])
    # TODO: Not implemented: Based on the content radius and the content that is
    # already stored, interest in provided content keys needs to be indicated
    # by setting bits in this BitList.
    # Do we need some protection here on a peer offering lots (64x) of content
    # that fits our Radius but is actually bogus?
    contentKeys = ContentKeysBitList.init(a.contentKeys.len)
    # TODO: What if we don't want any of the content? Reply with empty bitlist
    # and a connectionId of all zeroes?
  encodeMessage(
    AcceptMessage(connectionId: connectionId, contentKeys: contentKeys))

proc messageHandler*(protocol: TalkProtocol, request: seq[byte],
    srcId: NodeId, srcUdpAddress: Address): seq[byte] =
  doAssert(protocol of PortalProtocol)

  let p = PortalProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message response", kind = message.kind
    case message.kind
    of MessageKind.ping:
      p.handlePing(message.ping)
    of MessageKind.findnode:
      p.handleFindNode(message.findNode)
    of MessageKind.findcontent:
      p.handleFindContent(message.findcontent)
    of MessageKind.offer:
      p.handleOffer(message.offer)
    else:
      @[]
  else:
    @[]

proc new*(T: type PortalProtocol,
    baseProtocol: protocol.Protocol,
    protocolId: seq[byte],
    contentHandler: ContentHandler,
    dataRadius = UInt256.high(),
    bootstrapRecords: openarray[Record] = [],
    distanceCalculator: DistanceCalculator = XorDistanceCalculator
    ): T =
  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    protocolId: protocolId,
    routingTable: RoutingTable.init(baseProtocol.localNode, DefaultBitsPerHop,
      DefaultTableIpLimits, baseProtocol.rng, distanceCalculator),
    baseProtocol: baseProtocol,
    dataRadius: dataRadius,
    handleContentRequest: contentHandler,
    bootstrapRecords: @bootstrapRecords)

  proto.baseProtocol.registerTalkProtocol(proto.protocolId, proto).expect(
    "Only one protocol should have this id")

  return proto

# Sends the discv5 talkreq nessage with provided Portal message, awaits and
# validates the proper response, and updates the Portal Network routing table.
proc reqResponse[Request: SomeMessage, Response: SomeMessage](
    p: PortalProtocol,
    toNode: Node,
    request: Request
    ): Future[PortalResult[Response]] {.async.} =
  let talkresp =
    await talkreq(p.baseProtocol, toNode, p.protocolId, encodeMessage(request))

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
    p.routingTable.setJustSeen(toNode)
  else:
    p.routingTable.replaceNode(toNode)

  return messageResponse

proc ping*(p: PortalProtocol, dst: Node):
    Future[PortalResult[PongMessage]] {.async.} =
  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let ping = PingMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  trace "Send message request", dstId = dst.id, kind = MessageKind.ping
  return await reqResponse[PingMessage, PongMessage](p, dst, ping)

proc findNode*(p: PortalProtocol, dst: Node, distances: List[uint16, 256]):
    Future[PortalResult[NodesMessage]] {.async.} =
  let fn = FindNodeMessage(distances: distances)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findnode
  # TODO Add nodes validation
  return await reqResponse[FindNodeMessage, NodesMessage](p, dst, fn)

proc findContent*(p: PortalProtocol, dst: Node, contentKey: ByteList):
    Future[PortalResult[ContentMessage]] {.async.} =
  let fc = FindContentMessage(contentKey: contentKey)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findcontent
  return await reqResponse[FindContentMessage, ContentMessage](p, dst, fc)

proc offer*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[AcceptMessage]] {.async.} =
  let offer = OfferMessage(contentKeys: contentKeys)

  trace "Send message request", dstId = dst.id, kind = MessageKind.offer

  return await reqResponse[OfferMessage, AcceptMessage](p, dst, offer)

  # TODO: Actually have to parse the offer message and get the uTP connection
  # id, and initiate an uTP stream with given uTP connection id to get the data
  # out.

proc recordsFromBytes(rawRecords: List[ByteList, 32]): seq[Record] =
  var records: seq[Record]
  for r in rawRecords.asSeq():
    var record: Record
    if record.fromBytes(r.asSeq()):
      records.add(record)

  records

proc lookupWorker(p: PortalProtocol, destNode: Node, target: NodeId):
    Future[seq[Node]] {.async.} =
  var nodes: seq[Node]
  # TODO: Distances are not correct here. Fix + tests
  let distances = lookupDistances(target, destNode.id)

  let nodesMessage = await p.findNode(destNode,  List[uint16, 256](distances))
  if nodesMessage.isOk():
    let records = recordsFromBytes(nodesMessage.get().enrs)
    # TODO: distance function is wrong inhere, fix + tests
    let verifiedNodes = verifyNodesRecords(records, destNode, EnrsResultLimit, distances)
    nodes.add(verifiedNodes)

    # Attempt to add all nodes discovered
    for n in nodes:
      discard p.routingTable.addNode(n)

  return nodes

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

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](Alpha)

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < Alpha:
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

proc handleFoundContentMessage(p: PortalProtocol, m: ContentMessage,
    dst: Node, nodes: var seq[Node]): LookupResult =
  if (m.enrs.len() != 0 and m.content.len() == 0):
    let records = recordsFromBytes(m.enrs)
    let verifiedNodes = verifyNodesRecords(records, dst, EnrsResultLimit)
    nodes.add(verifiedNodes)

    for n in nodes:
      # Attempt to add all nodes discovered
      discard p.routingTable.addNode(n)

    return LookupResult(kind: Nodes, nodes: nodes)
  elif (m.content.len() != 0 and m.enrs.len() == 0):
    return LookupResult(kind: Content, content: m.content)
  elif ((m.content.len() != 0 and m.enrs.len() != 0)):
    # Both content and enrs are filled, which means protocol breach. For now
    # just logging offending node to quickly identify it
    warn "Invalid foundcontent response form node ", uri = toURI(dst.record)
    return LookupResult(kind: Nodes, nodes: nodes)
  else:
    return LookupResult(kind: Nodes, nodes: nodes)

proc contentLookupWorker(p: PortalProtocol, destNode: Node, target: ByteList):
    Future[LookupResult] {.async.} =
  var nodes: seq[Node]

  let contentMessageResponse = await p.findContent(destNode,  target)

  if contentMessageResponse.isOk():
    return handleFoundContentMessage(
      p, contentMessageResponse.get(), destNode, nodes)
  else:
    return LookupResult(kind: Nodes, nodes: nodes)

# TODO ContentLookup and Lookup look almost exactly the same, also lookups in other
# networks will probably be very similar. Extract lookup function to separate module
# and make it more generaic
proc contentLookup*(p: PortalProtocol, target: ByteList, targetId: UInt256):
    Future[Option[ByteList]] {.async.} =
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

  var pendingQueries = newSeqOfCap[Future[LookupResult]](Alpha)

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < Alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.contentLookupWorker(n, target))
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

    let lookupResult = query.read

    # TODO: Remove node on timed-out query? To handle failure better, LookUpResult
    # should have third enum option like failure.
    case lookupResult.kind
    of Nodes:
      for n in lookupResult.nodes:
        if not seen.containsOrIncl(n.id):
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

      return some(lookupResult.content)

  return none[ByteList]()

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

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](Alpha)

  while true:
    var i = 0
    while i < min(queryBuffer.len, k) and pendingQueries.len < Alpha:
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
  ## Seed the table with nodes from the discv5 table and with specifically
  ## provided bootstrap nodes. The latter are then supposed to be nodes
  ## supporting the wire protocol for the specific content network.
  # Note: We allow replacing the bootstrap nodes in the routing table as it is
  # possible that some of these are not supporting the specific portal network.

  # TODO: Picking some nodes from discv5 routing table now. Should definitely
  # add supported Portal network info in a k:v pair in the ENRs and filter on
  # that.
  let closestNodes = p.baseProtocol.neighbours(
    NodeId.random(p.baseProtocol.rng[]), seenOnly = true)

  for node in closestNodes:
    if p.routingTable.addNode(node) == Added:
      debug "Added node from discv5 routing table", uri = toURI(node.record)
    else:
      debug "Node from discv5 routing table could not be added", uri = toURI(node.record)

  # Seed the table with bootstrap nodes.
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
  let selfQuery = await p.query(p.baseProtocol.localNode.id)
  trace "Discovered nodes in self target query", nodes = selfQuery.len

  for i in 0..<InitialLookups:
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
      let nodes = await p.findNode(n, List[uint16, 256](@[0'u16]))
      if nodes.isOk():
        let records = recordsFromBytes(nodes.get().enrs)
        # TODO: distance function is wrong inhere, fix + tests
        let verifiedNodes = verifyNodesRecords(records, n, EnrsResultLimit, @[0'u16])
        if verifiedNodes.len > 0:
          discard p.routingTable.addNode(verifiedNodes[0])

proc revalidateLoop(p: PortalProtocol) {.async.} =
  ## Loop which revalidates the nodes in the routing table by sending the ping
  ## message.
  try:
    while true:
      await sleepAsync(milliseconds(p.baseProtocol.rng[].rand(RevalidateMax)))
      let n = p.routingTable.nodeToRevalidate()
      if not n.isNil:
        asyncSpawn p.revalidateNode(n)
  except CancelledError:
    trace "revalidateLoop canceled"

proc refreshLoop(p: PortalProtocol) {.async.} =
  ## Loop that refreshes the routing table by starting a random query in case
  ## no queries were done since `refreshInterval` or more.
  ## It also refreshes the majority address voted for via pong responses.
  try:
    await p.populateTable()

    while true:
      let currentTime = now(chronos.Moment)
      if currentTime > (p.lastLookup + RefreshInterval):
        let randomQuery = await p.queryRandom()
        trace "Discovered nodes in random target query", nodes = randomQuery.len
        debug "Total nodes in routing table", total = p.routingTable.len()

      await sleepAsync(RefreshInterval)
  except CancelledError:
    trace "refreshLoop canceled"

proc start*(p: PortalProtocol) =
  p.seedTable()

  p.refreshLoop = refreshLoop(p)
  p.revalidateLoop = revalidateLoop(p)

proc stop*(p: PortalProtocol) =
  if not p.revalidateLoop.isNil:
    p.revalidateLoop.cancel()
  if not p.refreshLoop.isNil:
    p.refreshLoop.cancel()
