# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sequtils, sets, algorithm, tables],
  stew/[results, byteutils], chronicles, chronos,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2],
  ./messages

logScope:
  topics = "overlay"

const
  OverlayProtocolId* = "overlay".toBytes()
  Alpha = 3 ## Kademlia concurrency factor
  LookupRequestLimit = 3 ## Amount of distances requested in a single Findnode
  ## message for a lookup or query
  RefreshInterval = 5.minutes ## Interval of launching a random query to
  ## refresh the routing table.
  RevalidateMax = 10000 ## Revalidation of a peer is done between 0 and this
  ## value in milliseconds
  InitialLookups = 1 ## Amount of lookups done when populating the routing table

type
  ByteList* = List[byte, 2048]

  SubProtocolPayload* = ByteList

  SubProtocolId* = seq[byte]

  SubProtocolDefinition* = object
    subProtocolId*: SubProtocolId
    subProtocolPayLoad*: SubProtocolPayload

  OverlaySubProtocol* = ref object
    subProtocolId*: SubProtocolId
    subProtocolPayLoad: SubProtocolPayload
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]

  OverlayProtocol* = ref object of TalkProtocol
    baseProtocol*: protocol.Protocol
    subProtocols: Table[SubProtocolId, OverlaySubProtocol]

  SubProtocolResult*[T] = Result[T, cstring]

# TODO:
# - setJustSeen and replaceNode on (all) message replies
# - On incoming portal ping of unknown node: add node to routing table by
# grabbing ENR from discv5 routing table (might not have it)?
# - ENRs with portal protocol capabilities as field?

proc subProtocolIdAsList*(p: OverlaySubProtocol): ByteList = List.init(p.subProtocolId, 2048)

proc handlePing(p: OverlaySubProtocol, ping: PingMessage):
    seq[byte] =
  let p = PongMessage(
    enrSeq: p.baseProtocol.localNode.record.seqNum, 
    subProtocolId: p.subProtocolIdAsList(), 
    subProtocolPayLoad: p.subProtocolPayLoad)

  encodeMessage(p)

proc handleFindNode(p: OverlaySubProtocol, fn: FindNodeMessage): seq[byte] =
  if fn.distances.len == 0:
    let enrs = List[ByteList, 32](@[])
    encodeMessage(NodesMessage(subProtocolId: p.subProtocolIdAsList(), total: 1, enrs: enrs))
  elif fn.distances.contains(0):
    # A request for our own record.
    let enr = ByteList(rlp.encode(p.baseProtocol.localNode.record))
    encodeMessage(NodesMessage(subProtocolId: p.subProtocolIdAsList(), total: 1, enrs: List[ByteList, 32](@[enr])))
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
        NodesMessage(subProtocolId: p.subProtocolIdAsList(), total: 1, enrs: List[ByteList, 32](List(enrs))))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList, 32](@[])
      encodeMessage(NodesMessage(subProtocolId: p.subProtocolIdAsList(), total: 1, enrs: enrs))

proc new(T: type OverlaySubProtocol, baseProtocol: protocol.Protocol, subProtocolId: SubProtocolId, subProtocolPayLoad: SubProtocolPayload): T =
  let proto = OverlaySubProtocol(
      subProtocolId: subProtocolId,
      subProtocolPayLoad: subProtocolPayLoad,
      baseProtocol: baseProtocol
    )

  proto.routingTable.init(baseProtocol.localNode, DefaultBitsPerHop,
    DefaultTableIpLimits, baseProtocol.rng)

  return proto

proc reqResponse[Request: OverlayMessage, Response: OverlayMessage](
      p: OverlaySubProtocol,
      toNode: Node,
      protocol: seq[byte],
      request: Request
    ): Future[SubProtocolResult[Response]] {.async.} = 
    let respResult = await talkreq(p.baseProtocol, toNode, protocol, encodeMessage(request))
    return respResult
      .flatMap(proc (x: seq[byte]): Result[Message, cstring] = decodeMessage(x))
      .flatMap(proc (m: Message): Result[Response, cstring] = 
        getInnerMessageResult[Response](m, cstring"Invalid message response received")
      )

proc ping*(p: OverlaySubProtocol, dst: Node):
    Future[SubProtocolResult[PongMessage]] {.async.} =
  let ping = PingMessage(
    enrSeq: p.baseProtocol.localNode.record.seqNum,
    subProtocolid: p.subProtocolIdAsList(),
    subProtocolPayload: p.subProtocolPayLoad)

  trace "Send message request", dstId = dst.id, kind = MessageKind.ping
  return await reqResponse[PingMessage, PongMessage](p, dst, OverlayProtocolId, ping)

proc findNode*(p: OverlaySubProtocol, dst: Node, distances: List[uint16, 256]):
    Future[SubProtocolResult[NodesMessage]] {.async.} =
  let fn = FindNodeMessage(subProtocolid: p.subProtocolIdAsList(), distances: distances)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findnode
  # TODO Add nodes validation
  return await reqResponse[FindNodeMessage, NodesMessage](p, dst, OverlayProtocolId, fn)

proc recordsFromBytes(rawRecords: List[ByteList, 32]): seq[Record] =
  var records: seq[Record]
  for r in rawRecords.asSeq():
    var record: Record
    if record.fromBytes(r.asSeq()):
      records.add(record)

  records

proc lookupDistances(target, dest: NodeId): seq[uint16] =
  var distances: seq[uint16]
  let td = logDist(target, dest)
  distances.add(td)
  var i = 1'u16
  while distances.len < LookupRequestLimit:
    if td + i < 256:
      distances.add(td + i)
    if td - i > 0'u16:
      distances.add(td - i)
    inc i

proc lookupWorker(p: OverlaySubProtocol, destNode: Node, target: NodeId):
    Future[seq[Node]] {.async.} =
  var nodes: seq[Node]
  let distances = lookupDistances(target, destNode.id)

  let nodesMessage = await p.findNode(destNode,  List[uint16, 256](distances))
  if nodesMessage.isOk():
    let records = recordsFromBytes(nodesMessage.get().enrs)
    let verifiedNodes = verifyNodesRecords(records, destNode, @[0'u16])
    nodes.add(verifiedNodes)

    # Attempt to add all nodes discovered
    for n in nodes:
      discard p.routingTable.addNode(n)

  return nodes

proc lookup*(p: OverlaySubProtocol, target: NodeId): Future[seq[Node]] {.async.} =
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
            cmp(distanceTo(x, target), distanceTo(n, target))
        ))

        if closestNodes.len > BUCKET_SIZE:
          closestNodes.del(closestNodes.high())

  p.lastLookup = now(chronos.Moment)
  return closestNodes

proc query*(p: OverlaySubProtocol, target: NodeId, k = BUCKET_SIZE): Future[seq[Node]]
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

proc queryRandom*(p: OverlaySubProtocol): Future[seq[Node]] =
  ## Perform a query for a random target, return all nodes discovered.
  p.query(NodeId.random(p.baseProtocol.rng[]))

proc seedTable(p: OverlaySubProtocol) =
  # TODO: Just picking something here for now. Maybe nodes should have info in
  # enrs which sub protocols they support
  let closestNodes = p.baseProtocol.neighbours(
    NodeId.random(p.baseProtocol.rng[]), seenOnly = true)

  for node in closestNodes:
    if p.routingTable.addNode(node) == Added:
      debug "Added node from discv5 routing table", uri = toURI(node.record)
    else:
      debug "Node from discv5 routing table could not be added", uri = toURI(node.record)

proc populateTable(p: OverlaySubProtocol) {.async.} =
  ## Do a set of initial lookups to quickly populate the table.
  # start with a self target query (neighbour nodes)
  let selfQuery = await p.query(p.baseProtocol.localNode.id)
  trace "Discovered nodes in self target query", nodes = selfQuery.len

  for i in 0..<InitialLookups:
    let randomQuery = await p.queryRandom()
    trace "Discovered nodes in random target query", nodes = randomQuery.len

  debug "Total nodes in routing table after populate",
    total = p.routingTable.len()

proc revalidateNode*(p: OverlaySubProtocol, n: Node) {.async.} =
  let pong = await p.ping(n)

  if pong.isOK():
    let res = pong.get()
    if res.enrSeq > n.record.seqNum:
      # Request new ENR
      let nodes = await p.findNode(n, List[uint16, 256](@[0'u16]))
      if nodes.isOk():
        let records = recordsFromBytes(nodes.get().enrs)
        let verifiedNodes = verifyNodesRecords(records, n, @[0'u16])
        if verifiedNodes.len > 0:
          discard p.routingTable.addNode(verifiedNodes[0])

proc revalidateLoop(p: OverlaySubProtocol) {.async.} =
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

proc refreshLoop(p: OverlaySubProtocol) {.async.} =
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

proc start*(p: OverlaySubProtocol) =
  p.seedTable()

  p.refreshLoop = refreshLoop(p)
  p.revalidateLoop = revalidateLoop(p)

proc stop*(p: OverlaySubProtocol) =
  if not p.revalidateLoop.isNil:
    p.revalidateLoop.cancel()
  if not p.refreshLoop.isNil:
    p.refreshLoop.cancel()

# Definition of OverlayProtocol

proc handleMessage(subProtocol: OverlaySubProtocol, m: OverlayMessage): seq[byte] =
  when m is PingMessage:
    subProtocol.handlePing(m)
  elif m is FindNodeMessage:
    subProtocol.handleFindNode(m)
  else:
    @[]

proc handleIfKnown(
  p: OverlayProtocol,
  message: OverlayMessage,
  subProtocolId: SubProtocolId
  ): seq[byte] =
  let subProtocol = p.subProtocols.getOrDefault(subProtocolId)
  if subProtocol.isNil():
    trace "Received message from not known protocol with id", id = subProtocolId
    @[]
  else:
    handleMessage(subProtocol, message)
    
proc messageHandler(protocol: TalkProtocol, request: seq[byte]): seq[byte] =
  doAssert(protocol of OverlayProtocol)

  let p = OverlayProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message response", kind = message.kind
    case message.kind
    of MessageKind.ping:
      let subProtocolId = message.ping.subProtocolId.asSeq()
      handleIfKnown(p, message.ping, subProtocolId)
    of MessageKind.findnode:
      let subProtocolId = message.findnode.subProtocolId.asSeq()
      handleIfKnown(p, message.findnode, subProtocolId)
    else:
      @[]
  else:
    @[]

proc new*(T: type OverlayProtocol, baseProtocol: protocol.Protocol): T =
  let proto = OverlayProtocol(
      protocolHandler: messageHandler,
      baseProtocol: baseProtocol
    )

  proto.baseProtocol.registerTalkProtocol(OverlayProtocolId, proto).expect(
    "Only one protocol should have this id")

  return proto

proc getSubProtocol*(p: OverlayProtocol, id: SubProtocolId): Option[OverlaySubProtocol] =
  let subProt = p.subProtocols.getOrDefault(id)
  if subProt.isNil():
    none[OverlaySubProtocol]()
  else:
    some(subProt)

## **Note:** Use it only when you are **absolutely sure** the subprotocol is present
proc unsafeGetSubProtocol*(p: OverlayProtocol, id: SubProtocolId): OverlaySubProtocol =
  getSubProtocol(p, id).unsafeGet()

proc registerSubProtocol*(o: OverlayProtocol, subProtocolDefinition: SubProtocolDefinition): OverlaySubProtocol =
  let newSub = OverlaySubProtocol.new(o.baseProtocol, subProtocolDefinition.subProtocolId, subProtocolDefinition.subProtocolPayLoad)
  o.subProtocols[subProtocolDefinition.subProtocolId] = newSub
  newSub
