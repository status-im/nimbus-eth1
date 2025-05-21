# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Implementation of the Portal wire protocol as specified at:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md

{.push raises: [].}

import
  std/[sequtils, sets, algorithm, tables],
  stew/[byteutils, leb128, endians2],
  results,
  chronicles,
  chronos,
  chronos/ratelimit,
  nimcrypto/hash,
  bearssl,
  ssz_serialization,
  metrics,
  faststreams,
  minilru,
  eth/rlp,
  eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2, nodes_verification],
  "."/[portal_stream, portal_protocol_config, ping_extensions, portal_protocol_version],
  ./messages

from std/times import epochTime # For system timestamp in traceContentLookup

export messages, routing_table, protocol

declareCounter portal_message_requests_incoming,
  "Portal wire protocol incoming message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_decoding_failures,
  "Portal wire protocol message decoding failures", labels = ["protocol_id"]
declareCounter portal_message_requests_outgoing,
  "Portal wire protocol outgoing message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_response_incoming,
  "Portal wire protocol incoming message responses",
  labels = ["protocol_id", "message_type"]
declareCounter portal_offer_accept_codes,
  "Portal wire protocol accept codes received from peers after sending offers",
  labels = ["protocol_id", "accept_code"]
declareCounter portal_handle_offer_accept_codes,
  "Portal wire protocol accept codes returned to peers when handing offers",
  labels = ["protocol_id", "accept_code"]

const requestBuckets = [1.0, 3.0, 5.0, 7.0, 9.0, Inf]
declareHistogram portal_lookup_node_requests,
  "Portal wire protocol amount of requests per node lookup",
  labels = ["protocol_id"],
  buckets = requestBuckets
declareHistogram portal_lookup_content_requests,
  "Portal wire protocol amount of requests per content lookup",
  labels = ["protocol_id"],
  buckets = requestBuckets
declareCounter portal_lookup_content_failures,
  "Portal wire protocol content lookup failures", labels = ["protocol_id"]

const contentKeysBuckets = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, Inf]
declareHistogram portal_content_keys_offered,
  "Portal wire protocol amount of content keys per offer message send",
  labels = ["protocol_id"],
  buckets = contentKeysBuckets
declareHistogram portal_content_keys_accepted,
  "Portal wire protocol amount of content keys per accept message received",
  labels = ["protocol_id"],
  buckets = contentKeysBuckets
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
declareCounter portal_content_cache_hits,
  "Portal wire protocol local content lookups that hit the content cache",
  labels = ["protocol_id"]
declareCounter portal_content_cache_misses,
  "Portal wire protocol local content lookups that don't hit the content cache",
  labels = ["protocol_id"]
declareCounter portal_offer_cache_hits,
  "Portal wire protocol local content lookups that hit the offer cache",
  labels = ["protocol_id"]
declareCounter portal_offer_cache_misses,
  "Portal wire protocol local content lookups that don't hit the offer cache",
  labels = ["protocol_id"]
declareCounter portal_poke_offers,
  "Portal wire protocol offers through poke mechanism", labels = ["protocol_id"]

# Note: These metrics are to get some idea on how many enrs are send on average.
# Relevant issue: https://github.com/ethereum/portal-network-specs/issues/136
const enrsBuckets = [0.0, 1.0, 3.0, 5.0, 8.0, 9.0, Inf]
declareHistogram portal_nodes_enrs_packed,
  "Portal wire protocol amount of enrs packed in a nodes message",
  labels = ["protocol_id"],
  buckets = enrsBuckets
# This one will currently hit the max numbers because all neighbours are send,
# not only the ones closer to the content.
declareHistogram portal_content_enrs_packed,
  "Portal wire protocol amount of enrs packed in a content message",
  labels = ["protocol_id"],
  buckets = enrsBuckets

const distanceBuckets = [
  float64 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253,
  254, 255, 256,
]
declareHistogram portal_find_content_log_distance,
  "Portal wire protocol logarithmic distance of requested content",
  labels = ["protocol_id"],
  buckets = distanceBuckets

declareHistogram portal_offer_log_distance,
  "Portal wire protocol logarithmic distance of offered content",
  labels = ["protocol_id"],
  buckets = distanceBuckets

logScope:
  topics = "portal_wire"

const
  enrsResultLimit* = 32 ## Maximum amount of ENRs in the total Nodes messages
  ## that will be processed
  refreshInterval = 5.minutes ## Interval of launching a random query to
  ## refresh the routing table.
  revalidateMax = 4000 ## Revalidation of a peer is done between 0 and this
  ## value in milliseconds
  initialLookups = 1 ## Amount of lookups done when populating the routing table

  ## Ban durations for banned nodes in the routing table
  NodeBanDurationInvalidResponse = 30.minutes
  NodeBanDurationContentLookupFailedValidation* = 60.minutes
  NodeBanDurationOfferFailedValidation* = 60.minutes
  NodeBanDurationBanOtherClients* = 24.hours # for testing only

type
  ToContentIdHandler* =
    proc(contentKey: ContentKeyByteList): results.Opt[ContentId] {.raises: [], gcsafe.}

  DbGetHandler* = proc(
    contentKey: ContentKeyByteList, contentId: ContentId
  ): results.Opt[seq[byte]] {.raises: [], gcsafe.}

  DbStoreHandler* = proc(
    contentKey: ContentKeyByteList, contentId: ContentId, content: seq[byte]
  ): bool {.raises: [], gcsafe.}

  DbContainsHandler* = proc(contentKey: ContentKeyByteList, contentId: ContentId): bool {.
    raises: [], gcsafe
  .}

  DbRadiusHandler* = proc(): UInt256 {.raises: [], gcsafe.}

  PortalProtocolId* = array[2, byte]

  RadiusCache* = LruCache[NodeId, UInt256]

  # Caches content fetched from the network during lookups.
  # Content outside our radius is also cached in order to improve performance
  # of queries which may lookup data outside our radius.
  ContentCache = LruCache[ContentId, seq[byte]]

  # Caches the content ids of the most recently received content offers.
  # Content is only stored in this cache if it falls within our radius and similarly
  # the cache is only checked if the content id is within our radius.
  OfferCache = LruCache[ContentId, bool]

  ContentKV* = object
    contentKey*: ContentKeyByteList
    content*: seq[byte]

  OfferRequestType = enum
    Direct
    Database

  OfferRequest = object
    dst: Node
    case kind: OfferRequestType
    of Direct:
      contentList: List[ContentKV, contentKeysLimit]
    of Database:
      contentKeys: ContentKeysList

  PortalProtocol* = ref object of TalkProtocol
    protocolId*: PortalProtocolId
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    toContentId*: ToContentIdHandler
    contentCache: ContentCache
    dbGet*: DbGetHandler
    dbPut*: DbStoreHandler
    dbContains*: DbContainsHandler
    dataRadius*: DbRadiusHandler
    bootstrapRecords*: seq[Record]
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]
    stream*: PortalStream
    radiusCache: RadiusCache
    offerCache*: OfferCache
    pingTimings: Table[NodeId, chronos.Moment]
    config*: PortalProtocolConfig
    pingExtensionCapabilities*: set[uint16]
    offerTokenBucket: TokenBucket

  PortalResult*[T] = Result[T, string]

  FoundContentKind* = enum
    Nodes
    Content

  FoundContent* = object
    src*: Node
    case kind*: FoundContentKind
    of Content:
      content*: seq[byte]
      utpTransfer*: bool
    of Nodes:
      nodes*: seq[Node]

  ContentLookupResult* = object
    content*: seq[byte]
    utpTransfer*: bool
    receivedFrom*: Node
    # List of nodes which do not have requested content, and for which
    # content is in their range
    nodesInterestedInContent*: seq[Node]

  TraceResponse* = object
    durationMs*: int64
    respondedWith*: seq[NodeId]

  NodeMetadata* = object
    enr*: Record
    distance*: UInt256

  TraceObject* = object
    origin*: NodeId
    targetId*: UInt256
    receivedFrom*: Opt[NodeId]
    responses*: Table[string, TraceResponse]
    metadata*: Table[string, NodeMetadata]
    cancelled*: seq[NodeId]
    startedAtMs*: int64

  TraceContentLookupResult* = object
    content*: Opt[seq[byte]]
    utpTransfer*: bool
    trace*: TraceObject

  NodeAddResult* = enum
    Added
    LocalNode
    Existing
    IpLimitReached
    ReplacementAdded
    ReplacementExisting
    NoAddress
    Banned
    IncompatibleVersion

func init*(T: type ContentKV, contentKey: ContentKeyByteList, content: seq[byte]): T =
  ContentKV(contentKey: contentKey, content: content)

func init*(
    T: type ContentLookupResult,
    content: seq[byte],
    utpTransfer: bool,
    receivedFrom: Node,
    nodesInterestedInContent: seq[Node],
): T =
  ContentLookupResult(
    content: content,
    utpTransfer: utpTransfer,
    receivedFrom: receivedFrom,
    nodesInterestedInContent: nodesInterestedInContent,
  )

func getProtocolId*(
    network: PortalNetwork, subnetwork: PortalSubnetwork
): PortalProtocolId =
  const portalPrefix = byte(0x50)

  case network
  of PortalNetwork.none, PortalNetwork.mainnet:
    case subnetwork
    of PortalSubnetwork.state:
      [portalPrefix, 0x0A]
    of PortalSubnetwork.history:
      [portalPrefix, 0x0B]
    of PortalSubnetwork.beacon:
      [portalPrefix, 0x0C]
    of PortalSubnetwork.transactionIndex:
      [portalPrefix, 0x0D]
    of PortalSubnetwork.verkleState:
      [portalPrefix, 0x0E]
    of PortalSubnetwork.transactionGossip:
      [portalPrefix, 0x0F]
  of PortalNetwork.angelfood:
    case subnetwork
    of PortalSubnetwork.state:
      [portalPrefix, 0x4A]
    of PortalSubnetwork.history:
      [portalPrefix, 0x4B]
    of PortalSubnetwork.beacon:
      [portalPrefix, 0x4C]
    of PortalSubnetwork.transactionIndex:
      [portalPrefix, 0x4D]
    of PortalSubnetwork.verkleState:
      [portalPrefix, 0x4E]
    of PortalSubnetwork.transactionGossip:
      [portalPrefix, 0x4F]

proc banNode*(p: PortalProtocol, nodeId: NodeId, period: chronos.Duration) =
  if not p.config.disableBanNodes:
    p.routingTable.banNode(nodeId, period)

proc isBanned*(p: PortalProtocol, nodeId: NodeId): bool =
  p.config.disableBanNodes == false and p.routingTable.isBanned(nodeId)

func `$`(id: PortalProtocolId): string =
  id.toHex()

func fromNodeStatus(T: type NodeAddResult, status: NodeStatus): T =
  case status
  of NodeStatus.Added: T.Added
  of NodeStatus.LocalNode: T.LocalNode
  of NodeStatus.Existing: T.Existing
  of NodeStatus.IpLimitReached: T.IpLimitReached
  of NodeStatus.ReplacementAdded: T.ReplacementAdded
  of NodeStatus.ReplacementExisting: T.ReplacementExisting
  of NodeStatus.NoAddress: T.NoAddress
  of NodeStatus.Banned: T.Banned

proc addNode*(p: PortalProtocol, node: Node): NodeAddResult =
  if node.highestCommonPortalVersion(localSupportedVersions).isOk():
    let status = p.routingTable.addNode(node)
    trace "Adding node to routing table", status, node
    NodeAddResult.fromNodeStatus(status)
  else:
    trace "Not adding node to routing table, no compatible protocol version", node
    NodeAddResult.IncompatibleVersion

proc addNode*(p: PortalProtocol, r: Record): bool =
  p.addNode(Node.fromRecord(r)) == NodeAddResult.Added

func getNode*(p: PortalProtocol, id: NodeId): Opt[Node] =
  p.routingTable.getNode(id)

func localNode*(p: PortalProtocol): Node =
  p.baseProtocol.localNode

func distance(p: PortalProtocol, a, b: NodeId): UInt256 =
  p.routingTable.distance(a, b)

func logDistance(p: PortalProtocol, a, b: NodeId): uint16 =
  p.routingTable.logDistance(a, b)

func inRange(
    p: PortalProtocol, nodeId: NodeId, nodeRadius: UInt256, contentId: ContentId
): bool =
  let distance = p.distance(nodeId, contentId)
  distance <= nodeRadius

template inRange*(p: PortalProtocol, contentId: ContentId): bool =
  p.inRange(p.localNode.id, p.dataRadius(), contentId)

func neighbours*(
    p: PortalProtocol,
    id: NodeId,
    k: int = BUCKET_SIZE,
    seenOnly = false,
    excluding = initHashSet[NodeId](),
): seq[Node] =
  func nodeNotExcluded(nodeId: NodeId): bool =
    not excluding.contains(nodeId)

  p.routingTable.neighbours(id, k, seenOnly, nodeNotExcluded)

func neighboursInRange*(
    p: PortalProtocol,
    id: ContentId,
    k: int = BUCKET_SIZE,
    seenOnly = false,
    excluding = initHashSet[NodeId](),
): seq[Node] =
  func nodeNotExcludedAndInRange(nodeId: NodeId): bool =
    if excluding.contains(nodeId):
      return false
    let radius = p.radiusCache.get(nodeId).valueOr:
      return false
    p.inRange(nodeId, radius, id)

  p.routingTable.neighbours(id, k, seenOnly, nodeNotExcludedAndInRange)

func truncateEnrs(
    nodes: seq[Node], maxSize: int, enrOverhead: int
): List[ByteList[2048], 32] =
  var enrs: List[ByteList[2048], 32]
  var totalSize = 0
  for n in nodes:
    let enr = ByteList[2048].init(n.record.raw)
    if totalSize + enr.len() + enrOverhead <= maxSize:
      let res = enrs.add(enr)
      # With max payload of discv5 and the sizes of ENRs this should not occur.
      doAssert(res, "32 limit will not be reached")
      totalSize = totalSize + enr.len() + enrOverhead
    else:
      break

  enrs

proc handlePingExtension(
    p: PortalProtocol,
    payloadType: uint16,
    encodedPayload: ByteList[1100],
    srcId: NodeId,
): (uint16, ByteList[1100]) =
  if payloadType notin p.pingExtensionCapabilities:
    return encodeErrorPayload(ErrorCode.ExtensionNotSupported)

  case payloadType
  of CapabilitiesType:
    let payload = decodeSsz(encodedPayload.asSeq(), CapabilitiesPayload).valueOr:
      return encodeErrorPayload(ErrorCode.FailedToDecodePayload)

    p.radiusCache.put(srcId, payload.data_radius)

    (
      payloadType,
      encodePayload(
        CapabilitiesPayload(
          client_info: NIMBUS_PORTAL_CLIENT_INFO,
          data_radius: p.dataRadius(),
          capabilities: List[uint16, MAX_CAPABILITIES_LENGTH].init(
            p.pingExtensionCapabilities.toSeq()
          ),
        )
      ),
    )
  of BasicRadiusType:
    let payload = decodeSsz(encodedPayload.asSeq(), BasicRadiusPayload).valueOr:
      return encodeErrorPayload(ErrorCode.FailedToDecodePayload)

    p.radiusCache.put(srcId, payload.data_radius)

    (payloadType, encodePayload(BasicRadiusPayload(data_radius: p.dataRadius())))
  of HistoryRadiusType:
    let payload = decodeSsz(encodedPayload.asSeq(), HistoryRadiusPayload).valueOr:
      return encodeErrorPayload(ErrorCode.FailedToDecodePayload)

    p.radiusCache.put(srcId, payload.data_radius)

    (
      payloadType,
      encodePayload(
        HistoryRadiusPayload(data_radius: p.dataRadius(), ephemeral_header_count: 0)
      ),
    )
  else:
    encodeErrorPayload(ErrorCode.ExtensionNotSupported)

proc handlePing(p: PortalProtocol, ping: PingMessage, srcId: NodeId): seq[byte] =
  # TODO: Need to think about the effect of malicious actor sending lots of
  # pings from different nodes to clear the LRU.
  let (payloadType, payload) =
    handlePingExtension(p, ping.payload_type, ping.payload, srcId)

  encodeMessage(
    PongMessage(
      enrSeq: p.localNode.record.seqNum, payload_type: payloadType, payload: payload
    )
  )

proc handleFindNodes(p: PortalProtocol, fn: FindNodesMessage): seq[byte] =
  if fn.distances.len == 0:
    let enrs = List[ByteList[2048], 32](@[])
    encodeMessage(NodesMessage(total: 1, enrs: enrs))
  elif fn.distances.contains(0):
    # A request for our own record.
    let enr = ByteList[2048](rlp.encode(p.localNode.record))
    encodeMessage(NodesMessage(total: 1, enrs: List[ByteList[2048], 32](@[enr])))
  else:
    let distances = fn.distances.asSeq()
    if distances.all(
      proc(x: uint16): bool =
        return x <= 256
    ):
      let nodes = p.routingTable.neighboursAtDistances(distances, seenOnly = true)

      # TODO: Total amount of messages is set fixed to 1 for now, else we would
      # need to either move the send of the talkresp messages here, or allow for
      # returning multiple messages.
      # On the long run, it might just be better to use a stream in these cases?
      # Size calculation is done to truncate the ENR results in order to not go
      # over the discv5 packet size limits. ENRs are sorted so the closest nodes
      # will still be passed.
      const
        nodesOverhead = 1 + 1 + 4 # msg id + total + container offset
        maxPayloadSize = maxDiscv5TalkRespPayload - nodesOverhead
        enrOverhead = 4 # per added ENR, 4 bytes offset overhead

      let enrs = truncateEnrs(nodes, maxPayloadSize, enrOverhead)
      portal_nodes_enrs_packed.observe(enrs.len().int64, labelValues = [$p.protocolId])

      encodeMessage(NodesMessage(total: 1, enrs: enrs))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList[2048], 32](@[])
      encodeMessage(NodesMessage(total: 1, enrs: enrs))

proc handleFindContent(
    p: PortalProtocol, fc: FindContentMessage, srcId: NodeId, version: uint8
): seq[byte] =
  const
    contentOverhead = 1 + 1 # msg id + SSZ Union selector
    maxPayloadSize = maxDiscv5TalkRespPayload - contentOverhead
    enrOverhead = 4 # per added ENR, 4 bytes offset overhead

  let contentId = p.toContentId(fc.contentKey).valueOr:
    # Return empty response when content key validation fails
    # TODO: Better would be to return no message at all? Needs changes on
    # discv5 layer.
    return @[]

  let logDistance = p.logDistance(contentId, p.localNode.id)
  portal_find_content_log_distance.observe(
    int64(logDistance), labelValues = [$p.protocolId]
  )

  # Clear out the timed out connections and pending transfers
  p.stream.pruneAllowedRequestConnections()

  # Check first if content is in range, as this is a cheaper operation
  if p.inRange(contentId) and p.stream.canAddPendingTransfer(srcId, contentId):
    let contentResult = p.dbGet(fc.contentKey, contentId)
    if contentResult.isOk():
      let content = contentResult.get()
      if content.len <= maxPayloadSize:
        return encodeMessage(
          ContentMessage(
            contentMessageType: contentType, content: ByteList[2048](content)
          )
        )
      else:
        p.stream.addPendingTransfer(srcId, contentId)
        let connectionId =
          p.stream.addContentRequest(srcId, contentId, content, version)

        return encodeMessage(
          ContentMessage(
            contentMessageType: connectionIdType, connectionId: connectionId
          )
        )

  # Node does not have the content, or content is not even in radius,
  # send closest neighbours to the requested content id.

  let
    closestNodes =
      p.neighbours(contentId, seenOnly = true, excluding = toHashSet([srcId]))
    enrs = truncateEnrs(closestNodes, maxPayloadSize, enrOverhead)
  portal_content_enrs_packed.observe(enrs.len().int64, labelValues = [$p.protocolId])

  encodeMessage(ContentMessage(contentMessageType: enrsType, enrs: enrs))

proc containsContent(
    p: PortalProtocol, contentKey: ContentKeyByteList, contentId: ContentId
): bool =
  if p.offerCache.contains(contentId):
    portal_offer_cache_hits.inc(labelValues = [$p.protocolId])
    true
  else:
    portal_offer_cache_misses.inc(labelValues = [$p.protocolId])
    p.dbContains(contentKey, contentId)

proc handleOffer(
    p: PortalProtocol, o: OfferMessage, srcId: NodeId
): Result[AcceptMessage, string] =
  # Early return when our contentQueue is full. This means there is a backlog
  # of content to process and potentially gossip around. Don't accept more
  # data in this case.
  if p.stream.contentQueue.full():
    portal_handle_offer_accept_codes.inc(
      o.contentKeys.len, labelValues = [$p.protocolId, $DeclinedRateLimited]
    )
    return ok(
      AcceptMessage(
        connectionId: Bytes2([byte 0x00, 0x00]),
        contentKeys:
          ContentKeysAcceptList.init(repeat(DeclinedRateLimited, o.contentKeys.len)),
      )
    )

  # Clear out the timed out connections and pending transfers
  p.stream.pruneAllowedOfferConnections()

  var
    contentKeysAcceptList = ContentKeysAcceptList.init(@[])
    contentKeys = ContentKeysList.init(@[])
    contentIds = newSeq[ContentId]()
    contentAccepted = false
  # TODO: Do we need some protection against a peer offering lots (64x) of
  # content that fits our Radius but is actually bogus?
  # Additional TODO, but more of a specification clarification: What if we don't
  # want any of the content? Reply with empty bitlist and a connectionId of
  # all zeroes but don't actually allow an uTP connection?
  for i, contentKey in o.contentKeys:
    let contentIdResult = p.toContentId(contentKey)
    if contentIdResult.isOk():
      let contentId = contentIdResult.get()

      let logDistance = p.logDistance(contentId, p.localNode.id)
      portal_offer_log_distance.observe(
        int64(logDistance), labelValues = [$p.protocolId]
      )

      if not p.inRange(contentId):
        discard contentKeysAcceptList.add(DeclinedNotWithinRadius)
      elif not p.stream.canAddPendingTransfer(srcId, contentId):
        discard contentKeysAcceptList.add(DeclinedInboundTransferInProgress)
      elif p.containsContent(contentKey, contentId):
        discard contentKeysAcceptList.add(DeclinedAlreadyStored)
      else:
        p.stream.addPendingTransfer(srcId, contentId)
        discard contentKeysAcceptList.add(Accepted)
        discard contentKeys.add(contentKey)
        contentIds.add(contentId)
        contentAccepted = true

      portal_handle_offer_accept_codes.inc(
        labelValues = [$p.protocolId, $contentKeysAcceptList[i]]
      )
    else:
      # Return empty response when content key validation fails
      return err("Invalid content key")

  let connectionId =
    if contentAccepted:
      p.stream.addContentOffer(srcId, contentKeys, contentIds)
    else:
      # When the node does not accept any of the content offered, reply with an
      # all zeroes bitlist and connectionId.
      # Note: What to do in this scenario is not defined in the Portal spec.
      Bytes2([byte 0x00, 0x00])

  ok(AcceptMessage(connectionId: connectionId, contentKeys: contentKeysAcceptList))

proc handleOffer(
    p: PortalProtocol, o: OfferMessage, srcId: NodeId, version: uint8
): seq[byte] =
  let response = p.handleOffer(o, srcId).valueOr:
    return @[]

  if version >= 1:
    encodeMessage(response)
  else:
    encodeMessage(AcceptMessageV0.fromAcceptMessage(response))

proc messageHandler(
    protocol: TalkProtocol,
    request: seq[byte],
    srcId: NodeId,
    srcUdpAddress: Address,
    nodeOpt: Opt[Node],
): seq[byte] =
  doAssert(protocol of PortalProtocol)

  logScope:
    protocolId = p.protocolId

  let p = PortalProtocol(protocol)

  if p.isBanned(srcId):
    # The sender of the message is in the temporary node ban list
    # so we don't process the message
    debug "Dropping message from banned node", srcId, srcUdpAddress
    return @[] # Reply with an empty response message

  let enr = p.baseProtocol.getEnr(srcId, srcUdpAddress).valueOr:
    # This should not occur as a session should be up and the ENR should have been added
    warn "No ENR found for node", srcId, srcUdpAddress
    return @[]

  let version = enr.highestCommonPortalVersion(localSupportedVersions).valueOr:
    debug "No compatible protocol version found", error, srcId, srcUdpAddress
    return @[]

  let decoded = decodeMessage(request, version)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message request", srcId, srcUdpAddress, kind = message.kind
    # Received a proper Portal message, check first if an ENR is provided by
    # the discovery v5 layer and add it to the portal network routing table.
    # If not provided through the handshake, try to get it from the discovery v5
    # routing table.
    # When the node would be eligable for the portal network routing table, it
    # is possible that it exists in the base discv5 routing table as the same
    # node ids are used. It is not certain at all however as more nodes might
    # exists on the base layer, and it will also depend on the distance,
    # order of lookups, etc.
    # Note: As third measure, could run a findNodes request with distance 0.
    if nodeOpt.isSome():
      let node = nodeOpt.value()
      discard p.addNode(node)
    else:
      let nodeOpt = p.baseProtocol.getNode(srcId)
      if nodeOpt.isSome():
        let node = nodeOpt.value()
        discard p.addNode(node)

    portal_message_requests_incoming.inc(labelValues = [$p.protocolId, $message.kind])

    case message.kind
    of MessageKind.ping:
      p.handlePing(message.ping, srcId)
    of MessageKind.findNodes:
      p.handleFindNodes(message.findNodes)
    of MessageKind.findContent:
      p.handleFindContent(message.findContent, srcId, version)
    of MessageKind.offer:
      p.handleOffer(message.offer, srcId, version)
    else:
      # This would mean a that Portal wire response message is being send over a
      # discv5 talkreq message.
      debug "Invalid Portal wire message type over talkreq", kind = message.kind
      @[]
  else:
    portal_message_decoding_failures.inc(labelValues = [$p.protocolId])
    debug "Packet decoding error", error = decoded.error, srcId, srcUdpAddress
    @[]

proc new*(
    T: type PortalProtocol,
    baseProtocol: protocol.Protocol,
    protocolId: PortalProtocolId,
    toContentId: ToContentIdHandler,
    dbGet: DbGetHandler,
    dbPut: DbStoreHandler,
    dbContains: DbContainsHandler,
    dbRadius: DbRadiusHandler,
    stream: PortalStream,
    bootstrapRecords: openArray[Record] = [],
    distanceCalculator: DistanceCalculator = XorDistanceCalculator,
    config: PortalProtocolConfig = defaultPortalProtocolConfig,
    pingExtensionCapabilities: set[uint16] = {CapabilitiesType},
): T =
  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    protocolId: protocolId,
    routingTable: RoutingTable.init(
      baseProtocol.localNode, config.bitsPerHop, config.tableIpLimits, baseProtocol.rng,
      distanceCalculator,
    ),
    baseProtocol: baseProtocol,
    toContentId: toContentId,
    contentCache:
      ContentCache.init(if config.disableContentCache: 0 else: config.contentCacheSize),
    dbGet: dbGet,
    dbPut: dbPut,
    dbContains: dbContains,
    dataRadius: dbRadius,
    bootstrapRecords: @bootstrapRecords,
    stream: stream,
    radiusCache: RadiusCache.init(config.radiusCacheSize),
    offerCache:
      OfferCache.init(if config.disableOfferCache: 0 else: config.offerCacheSize),
    pingTimings: Table[NodeId, chronos.Moment](),
    config: config,
    pingExtensionCapabilities: pingExtensionCapabilities,
    # 0 seconds here indicates no timeout on the TokenBucket which means we need
    # to manually call replenish to return tokens to the bucket after usage.
    offerTokenBucket: TokenBucket.new(config.maxConcurrentOffers, 0.seconds),
  )

  proto.baseProtocol.registerTalkProtocol(@(proto.protocolId), proto).expect(
    "Only one protocol should have this id"
  )

  proto

# Sends the discv5 talkreq message with provided Portal message, awaits and
# validates the proper response, and updates the Portal Network routing table.
proc reqResponse[Request: SomeMessage, Response: SomeMessage](
    p: PortalProtocol, dst: Node, request: Request, version: uint8 = 1'u8
): Future[PortalResult[Response]] {.async: (raises: [CancelledError]).} =
  logScope:
    protocolId = p.protocolId

  trace "Send message request", dstId = dst.id, kind = messageKind(Request)
  portal_message_requests_outgoing.inc(
    labelValues = [$p.protocolId, $messageKind(Request)]
  )

  let talkResp =
    await talkReq(p.baseProtocol, dst, @(p.protocolId), encodeMessage(request))

  # Note: Failure of `decodeMessage` might also simply mean that the peer is
  # not supporting the specific talk protocol, as according to specification
  # an empty response needs to be send in that case.
  # See: https://github.com/ethereum/devp2p/blob/master/discv5/discv5-wire.md#talkreq-request-0x05

  let messageResponse = talkResp
    .mapErr(
      proc(x: cstring): string =
        $x
    )
    .flatMap(
      proc(x: seq[byte]): Result[Message, string] =
        decodeMessage(x, version)
    )
    .flatMap(
      proc(m: Message): Result[Response, string] =
        let r = getInnerMessage[Response](m)
        # Ban nodes that that send wrong type of response message
        if r.isErr():
          p.banNode(dst.id, NodeBanDurationInvalidResponse)
        return r
    )

  if messageResponse.isOk():
    trace "Received message response",
      srcId = dst.id, srcAddress = dst.address, kind = messageKind(Response)
    portal_message_response_incoming.inc(
      labelValues = [$p.protocolId, $messageKind(Response)]
    )

    p.routingTable.setJustSeen(dst)
  else:
    debug "Error receiving message response",
      error = messageResponse.error, srcId = dst.id, srcAddress = dst.address
    p.pingTimings.del(dst.id)
    p.routingTable.replaceNode(dst)

  return messageResponse

proc pingImpl*(
    p: PortalProtocol, dst: Node
): Future[PortalResult[PongMessage]] {.async: (raises: [CancelledError]).} =
  let pingPayload = encodePayload(
    CapabilitiesPayload(
      client_info: NIMBUS_PORTAL_CLIENT_INFO,
      data_radius: p.dataRadius(),
      capabilities:
        List[uint16, MAX_CAPABILITIES_LENGTH].init(p.pingExtensionCapabilities.toSeq()),
    )
  )

  let ping = PingMessage(
    enrSeq: p.localNode.record.seqNum,
    payload_type: CapabilitiesType,
    payload: pingPayload,
  )

  return await reqResponse[PingMessage, PongMessage](p, dst, ping)

proc findNodesImpl*(
    p: PortalProtocol, dst: Node, distances: List[uint16, 256]
): Future[PortalResult[NodesMessage]] {.async: (raises: [CancelledError]).} =
  let fn = FindNodesMessage(distances: distances)

  # TODO Add nodes validation
  return await reqResponse[FindNodesMessage, NodesMessage](p, dst, fn)

proc findContentImpl*(
    p: PortalProtocol, dst: Node, contentKey: ContentKeyByteList
): Future[PortalResult[ContentMessage]] {.async: (raises: [CancelledError]).} =
  let fc = FindContentMessage(contentKey: contentKey)

  return await reqResponse[FindContentMessage, ContentMessage](p, dst, fc)

proc offerImpl*(
    p: PortalProtocol, dst: Node, contentKeys: ContentKeysList, version: uint8 = 1'u8
): Future[PortalResult[AcceptMessage]] {.async: (raises: [CancelledError]).} =
  let offer = OfferMessage(contentKeys: contentKeys)

  return await reqResponse[OfferMessage, AcceptMessage](p, dst, offer, version)

proc recordsFromBytes(rawRecords: List[ByteList[2048], 32]): PortalResult[seq[Record]] =
  var records: seq[Record]
  for r in rawRecords.asSeq():
    let record = enr.Record.fromBytes(r.asSeq()).valueOr:
      # If any of the ENRs is invalid, fail immediatly. This is similar as what
      # is done on the discovery v5 layer.
      return err("Deserialization of an ENR failed")

    records.add(record)

  ok(records)

proc ping*(
    p: PortalProtocol, dst: Node
): Future[PortalResult[(uint64, uint16, CapabilitiesPayload)]] {.
    async: (raises: [CancelledError])
.} =
  # Fail if no common portal version is found
  let _ = ?dst.highestCommonPortalVersion(localSupportedVersions)

  if p.isBanned(dst.id):
    return err("destination node is banned")

  let pong = ?(await p.pingImpl(dst))

  # Update last time we pinged this node
  p.pingTimings[dst.id] = now(chronos.Moment)

  # Note: currently only decoding as capabilities payload as this is the only
  # one that we support sending.
  if pong.payload_type != CapabilitiesType:
    return err("Pong message contains invalid or error payload")

  let payload = decodeSsz(pong.payload.asSeq(), CapabilitiesPayload).valueOr:
    return err("Pong message contains invalid CapabilitiesPayload")

  p.radiusCache.put(dst.id, payload.data_radius)

  if p.config.banOtherClients and payload.client_info != NIMBUS_PORTAL_CLIENT_INFO:
    p.banNode(dst.id, NodeBanDurationBanOtherClients)

  ok((pong.enrSeq, pong.payload_type, payload))

proc findNodes*(
    p: PortalProtocol, dst: Node, distances: seq[uint16]
): Future[PortalResult[seq[Node]]] {.async: (raises: [CancelledError]).} =
  # Fail if no common portal version is found
  let _ = ?dst.highestCommonPortalVersion(localSupportedVersions)

  if p.isBanned(dst.id):
    return err("destination node is banned")

  let response = ?(await p.findNodesImpl(dst, List[uint16, 256](distances)))

  let records = ?recordsFromBytes(response.enrs)
  # TODO: distance function is wrong here for state, fix + tests
  ok(
    verifyNodesRecords(records, dst, enrsResultLimit, distances).filterIt(
      not p.isBanned(it.id)
    )
  )

proc findContent*(
    p: PortalProtocol, dst: Node, contentKey: ContentKeyByteList
): Future[PortalResult[FoundContent]] {.async: (raises: [CancelledError]).} =
  # Fail if no common portal version is found
  let version = ?dst.highestCommonPortalVersion(localSupportedVersions)

  logScope:
    node = dst
    contentKey
    version

  if p.isBanned(dst.id):
    return err("destination node is banned")

  let response = ?(await p.findContentImpl(dst, contentKey))

  case response.contentMessageType
  of connectionIdType:
    let nodeAddress = NodeAddress.init(dst).valueOr:
      # This should not happen as it comes a after succesfull talkreq/talkresp
      return err("Trying to connect to node with unknown address: " & $dst.id)

    let socket =
      ?(
        await p.stream.connectTo(
          # uTP protocol uses BE for all values in the header, incl. connection id
          nodeAddress,
          uint16.fromBytesBE(response.connectionId),
        )
      )

    proc readContentValueVersioned(
        socket: UtpSocket[NodeAddress]
    ): Future[Result[seq[byte], string]] {.async: (raises: [CancelledError]).} =
      if version >= 1:
        await socket.readContentValue()
      else:
        let bytes = await socket.read()
        if bytes.len() == 0:
          err("No bytes read")
        else:
          ok(bytes)

    try:
      # Read one content item from the socket, fails on invalid length prefix
      let readFut = socket.readContentValueVersioned()

      readFut.cancelCallback = proc(udate: pointer) {.gcsafe.} =
        debug "Socket read cancelled", socketKey = socket.socketKey
        # In case this `findContent` gets cancelled while reading the data,
        # send a FIN and clean up the socket.
        socket.close()

      if await readFut.withTimeout(p.stream.contentReadTimeout):
        let content = (await readFut).valueOr:
          socket.close() # Sending FIN to remote
          return err("Error reading content item from socket: " & error)

        trace "Content value read from socket", socketKey = socket.socketKey
        socket.destroy()

        return
          ok(FoundContent(src: dst, kind: Content, content: content, utpTransfer: true))
      else:
        debug "Socket read time-out", socketKey = socket.socketKey
        # Note: This might look a bit strange, but not doing a socket.close()
        # here as this is already done internally. utp_socket `checkTimeouts`
        # already does a socket.destroy() on timeout. Might want to change the
        # API on this later though.
        return err("Reading data from socket timed out, content request failed")
    except CancelledError as exc:
      # even though we already installed cancelCallback on readFut, it is worth
      # catching CancelledError in case that withTimeout throws CancelledError
      # but readFut have already finished.
      debug "Socket read cancelled", socketKey = socket.socketKey

      socket.close()
      raise exc
  of contentType:
    ok(
      FoundContent(
        src: dst, kind: Content, content: response.content.asSeq(), utpTransfer: false
      )
    )
  of enrsType:
    let records = ?recordsFromBytes(response.enrs)
    let verifiedNodes = verifyNodesRecords(records, dst, enrsResultLimit)

    ok(
      FoundContent(
        src: dst, kind: Nodes, nodes: verifiedNodes.filterIt(not p.isBanned(it.id))
      )
    )

proc getContentKeys(o: OfferRequest): ContentKeysList =
  case o.kind
  of Direct:
    var contentKeys: ContentKeysList
    for info in o.contentList:
      discard contentKeys.add(info.contentKey)

    contentKeys
  of Database:
    o.contentKeys

func getMaxOfferedContentKeys*(protocolIdLen: uint32, maxKeySize: uint32): int =
  ## Calculates how many ContentKeys will fit in one offer message which
  ## will be small enough to fit into discv5 limit.
  ## This is necessary as contentKeysLimit (64) is sometimes too big, and even
  ## half of this can be too much to fit into discv5 limits.

  let maxTalkReqPayload = maxDiscv5PacketSize - getTalkReqOverhead(int(protocolIdLen))
  # To calculate how much bytes, `n` content keys of size `maxKeySize` will take
  # we can use following equation:
  # bytes = (n * (maxKeySize + perContentKeyOverhead)) + offerMessageOverhead
  # to calculate maximal number of keys which will given space this can be
  # transformed to:
  # n = trunc((bytes - offerMessageOverhead) / (maxKeySize + perContentKeyOverhead))
  return ((maxTalkReqPayload - 5) div (int(maxKeySize) + 4))

proc offer(
    p: PortalProtocol, o: OfferRequest
): Future[PortalResult[ContentKeysAcceptList]] {.async: (raises: [CancelledError]).} =
  ## Offer triggers offer-accept interaction with one peer
  ## Whole flow has two phases:
  ## 1. Come to an agreement on what content to transfer, by using offer and
  ## accept messages.
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

  # Fail if no common portal version is found
  let version = ?o.dst.highestCommonPortalVersion(localSupportedVersions)

  let contentKeys = getContentKeys(o)

  logScope:
    node = o.dst
    contentKeys
    version

  trace "Offering content"

  portal_content_keys_offered.observe(
    contentKeys.len().int64, labelValues = [$p.protocolId]
  )

  if p.isBanned(o.dst.id):
    return err("destination node is banned")

  let response = ?(await p.offerImpl(o.dst, contentKeys, version))

  let contentKeysLen =
    case o.kind
    of Direct:
      o.contentList.len()
    of Database:
      o.contentKeys.len()

  if response.contentKeys.len() != contentKeysLen:
    # TODO:
    # When there is such system, the peer should get scored negatively here.
    error "Accepted content key accept list has invalid size",
      acceptListLen = response.contentKeys.len(), contentKeysLen
    return err("Accepted content key accept list has invalid size")

  var acceptedKeysAmount = 0
  for code in response.contentKeys:
    portal_offer_accept_codes.inc(labelValues = [$p.protocolId, $code])
    if code == Accepted:
      inc(acceptedKeysAmount)

  portal_content_keys_accepted.observe(
    acceptedKeysAmount.int64, labelValues = [$p.protocolId]
  )
  if acceptedKeysAmount == 0:
    debug "No content accepted"
    # Don't open an uTP stream if no content was requested
    return ok(response.contentKeys)

  let nodeAddress = NodeAddress.init(o.dst).valueOr:
    # This should not happen as it comes a after succesfull talkreq/talkresp
    return err("Trying to connect to node with unknown address: " & $o.dst.id)

  let socket =
    ?(await p.stream.connectTo(nodeAddress, uint16.fromBytesBE(response.connectionId)))

  case o.kind
  of Direct:
    for i, b in response.contentKeys:
      if b == Accepted:
        let content = o.contentList[i].content
        var output = memoryOutput()
        try:
          output.write(toBytes(content.lenu32, Leb128).toOpenArray())
          output.write(content)
        except IOError as e:
          # This should not happen in case of in-memory streams
          raiseAssert e.msg

        let dataWritten = (await socket.write(output.getOutput)).valueOr:
          debug "Error writing requested data", error
          # No point in trying to continue writing data
          socket.close()
          return err("Error writing requested data")

        trace "Offered content item send", dataWritten = dataWritten
  of Database:
    for i, b in response.contentKeys:
      if b == Accepted:
        let
          contentKey = o.contentKeys[i]
          contentIdResult = p.toContentId(contentKey)
        if contentIdResult.isOk():
          let
            contentId = contentIdResult.get()
            contentResult = p.dbGet(contentKey, contentId)

          var output = memoryOutput()
          if contentResult.isOk():
            let content = contentResult.get()
            try:
              output.write(toBytes(content.lenu32, Leb128).toOpenArray())
              output.write(content)
            except IOError as e:
              # This should not happen in case of in-memory streams
              raiseAssert e.msg
          else:
            try:
              # When data turns out missing, add a 0 size varint
              output.write(toBytes(0'u8, Leb128).toOpenArray())
            except IOError as e:
              raiseAssert e.msg

          let dataWritten = (await socket.write(output.getOutput)).valueOr:
            debug "Error writing requested data", error
            # No point in trying to continue writing data
            socket.close()
            return err("Error writing requested data")

          trace "Offered content item send", dataWritten = dataWritten

  await socket.closeWait()
  trace "Content successfully offered"

  ok(response.contentKeys)

proc offer*(
    p: PortalProtocol, dst: Node, contentKeys: ContentKeysList
): Future[PortalResult[ContentKeysAcceptList]] {.async: (raises: [CancelledError]).} =
  let req = OfferRequest(dst: dst, kind: Database, contentKeys: contentKeys)
  await p.offer(req)

proc offer*(
    p: PortalProtocol, dst: Node, content: seq[ContentKV]
): Future[PortalResult[ContentKeysAcceptList]] {.async: (raises: [CancelledError]).} =
  if len(content) > contentKeysLimit:
    return err("Cannot offer more than 64 content items")
  if len(content) == 0:
    return err("Cannot offer empty content list")

  let contentList = List[ContentKV, contentKeysLimit].init(content)
  let req = OfferRequest(dst: dst, kind: Direct, contentList: contentList)
  await p.offer(req)

proc offerRateLimited*(
    p: PortalProtocol, offer: OfferRequest
): Future[PortalResult[ContentKeysAcceptList]] {.async: (raises: [CancelledError]).} =
  try:
    await p.offerTokenBucket.consume(1)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raiseAssert(e.msg) # Shouldn't happen

  let res = await p.offer(offer)
  if res.isOk():
    portal_gossip_offers_successful.inc(labelValues = [$p.protocolId])
  else:
    portal_gossip_offers_failed.inc(labelValues = [$p.protocolId])

  p.offerTokenBucket.replenish(1)

  res

proc lookupWorker(
    p: PortalProtocol, dst: Node, target: NodeId
): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  let distances = lookupDistances(target, dst.id)
  let nodesMessage = await p.findNodes(dst, distances)
  if nodesMessage.isOk():
    let nodes = nodesMessage.get()
    # Attempt to add all nodes discovered
    for n in nodes:
      discard p.addNode(n)
    return nodes
  else:
    return @[]

proc lookup*(
    p: PortalProtocol, target: NodeId
): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.neighbours(target, BUCKET_SIZE, seenOnly = false)

  var asked, seen = HashSet[NodeId]()
  asked.incl(p.localNode.id) # No need to ask our own node
  seen.incl(p.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries =
    newSeqOfCap[Future[seq[Node]].Raising([CancelledError])](p.config.alpha)
  var requestAmount = 0'i64

  while true:
    var i = 0
    # Doing `p.config.alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < p.config.alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
        requestAmount.inc()
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query =
      try:
        await one(pendingQueries)
      except ValueError:
        raiseAssert("pendingQueries should not have been empty")

    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = await query
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        # If it wasn't seen before, insert node while remaining sorted
        closestNodes.insert(
          n,
          closestNodes.lowerBound(
            n,
            proc(x: Node, n: Node): int =
              cmp(p.distance(x.id, target), p.distance(n.id, target)),
          ),
        )

        if closestNodes.len > BUCKET_SIZE:
          closestNodes.del(closestNodes.high())

  portal_lookup_node_requests.observe(requestAmount, labelValues = [$p.protocolId])
  p.lastLookup = now(chronos.Moment)
  return closestNodes

proc triggerPoke*(
    p: PortalProtocol,
    nodes: seq[Node],
    contentKey: ContentKeyByteList,
    content: seq[byte],
): Future[void] {.async: (raises: [CancelledError]).} =
  ## In order to properly test gossip mechanisms (e.g. in Portal Hive),
  ## we need the option to turn off the POKE functionality as it influences
  ## how data moves around the network.
  if p.config.disablePoke:
    return
  ## Triggers asynchronous offer-accept interaction to provided nodes.
  ## Provided content should be in range of provided nodes.
  for node in nodes:
    if p.offerTokenBucket.tryConsume(1):
      # tryConsume actually deducts tokens and there is currently
      # no API to check the remaining capacity of the bucket so we just
      # add the token back here
      p.offerTokenBucket.replenish(1)

      let
        contentKV = ContentKV(contentKey: contentKey, content: content)
        list = List[ContentKV, contentKeysLimit].init(@[contentKV])
        req = OfferRequest(dst: node, kind: Direct, contentList: list)
      discard await p.offerRateLimited(req)

      portal_poke_offers.inc(labelValues = [$p.protocolId])
    else:
      # The offerTokenBucket is at capacity so do not start more offer-accept interactions
      return

# TODO ContentLookup and Lookup look almost exactly the same, also lookups in other
# networks will probably be very similar. Extract lookup function to separate module
# and make it more generaic
proc contentLookup*(
    p: PortalProtocol, target: ContentKeyByteList, targetId: UInt256
): Future[Opt[ContentLookupResult]] {.async: (raises: [CancelledError]).} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.neighbours(targetId, BUCKET_SIZE, seenOnly = false)

  # Shuffling the order of the nodes in order to not always hit the same node
  # first for the same request.
  p.baseProtocol.rng[].shuffle(closestNodes)

  # Sort closestNodes so that nodes that are in range of the target content
  # are queried first
  proc nodesCmp(x, y: Node): int =
    let
      xRadius = p.radiusCache.get(x.id)
      yRadius = p.radiusCache.get(y.id)

    if xRadius.isSome() and p.inRange(x.id, xRadius.unsafeGet(), targetId):
      -1
    elif yRadius.isSome() and p.inRange(y.id, yRadius.unsafeGet(), targetId):
      1
    else:
      0

  closestNodes.sort(nodesCmp)

  var asked, seen = HashSet[NodeId]()
  asked.incl(p.localNode.id) # No need to ask our own node
  seen.incl(p.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[
    Future[PortalResult[FoundContent]].Raising([CancelledError])
  ](p.config.alpha)
  var requestAmount = 0'i64

  var nodesWithoutContent: seq[Node] = newSeq[Node]()

  while true:
    var i = 0
    # Doing `p.config.alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < p.config.alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.findContent(n, target))
        requestAmount.inc()
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query =
      try:
        await one(pendingQueries)
      except ValueError:
        raiseAssert("pendingQueries should not have been empty")

    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let contentResult = await query
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
            discard p.addNode(n)
            # If it wasn't seen before, insert node while remaining sorted
            closestNodes.insert(
              n,
              closestNodes.lowerBound(
                n,
                proc(x: Node, n: Node): int =
                  cmp(p.distance(x.id, targetId), p.distance(n.id, targetId)),
              ),
            )

            if closestNodes.len > BUCKET_SIZE:
              closestNodes.del(closestNodes.high())
      of Content:
        # cancel any pending queries as the content has been found
        for f in pendingQueries:
          f.cancelSoon()
        portal_lookup_content_requests.observe(
          requestAmount, labelValues = [$p.protocolId]
        )
        return Opt.some(
          ContentLookupResult.init(
            content.content, content.utpTransfer, content.src, nodesWithoutContent
          )
        )
    else:
      debug "Content query failed", error = contentResult.error
      # Note: Not doing any retries here as retries can/should be done on a
      # higher layer. However, depending on the failure we could attempt a retry,
      # e.g. on uTP specific errors.
      discard

  portal_lookup_content_failures.inc(labelValues = [$p.protocolId])
  return Opt.none(ContentLookupResult)

proc traceContentLookup*(
    p: PortalProtocol, target: ContentKeyByteList, targetId: UInt256
): Future[TraceContentLookupResult] {.async: (raises: [CancelledError]).} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  let startedAt = Moment.now()
  # Need to use a system clock and not the mono clock for this.
  let startedAtMs = int64(times.epochTime() * 1000)

  var closestNodes = p.neighbours(targetId, BUCKET_SIZE, seenOnly = false)
  # Shuffling the order of the nodes in order to not always hit the same node
  # first for the same request.
  p.baseProtocol.rng[].shuffle(closestNodes)

  # Sort closestNodes so that nodes that are in range of the target content
  # are queried first
  proc nodesCmp(x, y: Node): int =
    let
      xRadius = p.radiusCache.get(x.id)
      yRadius = p.radiusCache.get(y.id)

    if xRadius.isSome() and p.inRange(x.id, xRadius.unsafeGet(), targetId):
      -1
    elif yRadius.isSome() and p.inRange(y.id, yRadius.unsafeGet(), targetId):
      1
    else:
      0

  closestNodes.sort(nodesCmp)

  var asked, seen = HashSet[NodeId]()
  asked.incl(p.localNode.id) # No need to ask our own node
  seen.incl(p.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  # Trace data
  var responses = Table[string, TraceResponse]()
  var metadata = Table[string, NodeMetadata]()
  # Local node should be part of the responses
  responses["0x" & $p.localNode.id] =
    TraceResponse(durationMs: 0, respondedWith: seen.toSeq())
  metadata["0x" & $p.localNode.id] = NodeMetadata(
    enr: p.localNode.record, distance: p.distance(p.localNode.id, targetId)
  )
  # And metadata for all the nodes local node closestNodes
  for node in closestNodes:
    metadata["0x" & $node.id] =
      NodeMetadata(enr: node.record, distance: p.distance(node.id, targetId))

  var pendingQueries = newSeqOfCap[
    Future[PortalResult[FoundContent]].Raising([CancelledError])
  ](p.config.alpha)
  var pendingNodes = newSeq[Node]()
  var requestAmount = 0'i64

  var nodesWithoutContent: seq[Node] = newSeq[Node]()

  while true:
    var i = 0
    # Doing `p.config.alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < p.config.alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.findContent(n, target))
        pendingNodes.add(n)
        requestAmount.inc()
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query =
      try:
        await one(pendingQueries)
      except ValueError:
        raiseAssert("pendingQueries should not have been empty")
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
      pendingNodes.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let contentResult = await query

    if contentResult.isOk():
      let content = contentResult.get()

      case content.kind
      of Nodes:
        let duration = chronos.milliseconds(Moment.now() - startedAt)

        let maybeRadius = p.radiusCache.get(content.src.id)
        if maybeRadius.isSome() and
            p.inRange(content.src.id, maybeRadius.unsafeGet(), targetId):
          # Only return nodes which may be interested in content.
          # No need to check for duplicates in nodesWithoutContent
          # as requests are never made two times to the same node.
          nodesWithoutContent.add(content.src)

        var respondedWith = newSeq[NodeId]()

        for n in content.nodes:
          let dist = p.distance(n.id, targetId)

          metadata["0x" & $n.id] = NodeMetadata(enr: n.record, distance: dist)
          respondedWith.add(n.id)

          if not seen.containsOrIncl(n.id):
            discard p.addNode(n)
            # If it wasn't seen before, insert node while remaining sorted
            closestNodes.insert(
              n,
              closestNodes.lowerBound(
                n,
                proc(x: Node, n: Node): int =
                  cmp(p.distance(x.id, targetId), dist),
              ),
            )

            if closestNodes.len > BUCKET_SIZE:
              closestNodes.del(closestNodes.high())

        let distance = p.distance(content.src.id, targetId)

        responses["0x" & $content.src.id] =
          TraceResponse(durationMs: duration, respondedWith: respondedWith)

        metadata["0x" & $content.src.id] =
          NodeMetadata(enr: content.src.record, distance: distance)
      of Content:
        let duration = chronos.milliseconds(Moment.now() - startedAt)

        # cancel any pending queries as the content has been found
        for f in pendingQueries:
          f.cancelSoon()
        portal_lookup_content_requests.observe(
          requestAmount, labelValues = [$p.protocolId]
        )

        let distance = p.distance(content.src.id, targetId)

        responses["0x" & $content.src.id] =
          TraceResponse(durationMs: duration, respondedWith: newSeq[NodeId]())

        metadata["0x" & $content.src.id] =
          NodeMetadata(enr: content.src.record, distance: distance)

        var pendingNodeIds = newSeq[NodeId]()

        for pn in pendingNodes:
          pendingNodeIds.add(pn.id)
          metadata["0x" & $pn.id] =
            NodeMetadata(enr: pn.record, distance: p.distance(pn.id, targetId))

        return TraceContentLookupResult(
          content: Opt.some(content.content),
          utpTransfer: content.utpTransfer,
          trace: TraceObject(
            origin: p.localNode.id,
            targetId: targetId,
            receivedFrom: Opt.some(content.src.id),
            responses: responses,
            metadata: metadata,
            cancelled: pendingNodeIds,
            startedAtMs: startedAtMs,
          ),
        )
    else:
      # Note: Not doing any retries here as retries can/should be done on a
      # higher layer. However, depending on the failure we could attempt a retry,
      # e.g. on uTP specific errors.
      # TODO: Ideally we get an empty response added to the responses table
      # and the metadata for the node that failed to respond. In the current
      # implementation there is no access to the node information however.
      discard

  portal_lookup_content_failures.inc(labelValues = [$p.protocolId])
  return TraceContentLookupResult(
    content: Opt.none(seq[byte]),
    utpTransfer: false,
    trace: TraceObject(
      origin: p.localNode.id,
      targetId: targetId,
      receivedFrom: Opt.none(NodeId),
      responses: responses,
      metadata: metadata,
      cancelled: newSeq[NodeId](),
      startedAtMs: startedAtMs,
    ),
  )

proc query*(
    p: PortalProtocol, target: NodeId, k = BUCKET_SIZE
): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  ## Query k nodes for the given target, returns all nodes found, including the
  ## nodes queried.
  ##
  ## This will take k nodes from the routing table closest to target and
  ## query them for nodes closest to target. If there are less than k nodes in
  ## the routing table, nodes returned by the first queries will be used.
  var queryBuffer = p.neighbours(target, k, seenOnly = false)

  var asked, seen = HashSet[NodeId]()
  asked.incl(p.localNode.id) # No need to ask our own node
  seen.incl(p.localNode.id) # No need to discover our own node
  for node in queryBuffer:
    seen.incl(node.id)

  var pendingQueries =
    newSeqOfCap[Future[seq[Node]].Raising([CancelledError])](p.config.alpha)

  while true:
    var i = 0
    while i < min(queryBuffer.len, k) and pendingQueries.len < p.config.alpha:
      let n = queryBuffer[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query =
      try:
        await one(pendingQueries)
      except ValueError:
        raiseAssert("pendingQueries should not have been empty")
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = await query
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        queryBuffer.add(n)

  p.lastLookup = now(chronos.Moment)
  return queryBuffer

proc queryRandom*(
    p: PortalProtocol
): Future[seq[Node]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Perform a query for a random target, return all nodes discovered.
  p.query(NodeId.random(p.baseProtocol.rng[]))

proc offerBatchGetPeerCount*(
    p: PortalProtocol, offers: seq[OfferRequest]
): Future[int] {.async: (raises: [CancelledError]).} =
  let futs = await allFinished(offers.mapIt(p.offerRateLimited(it)))

  var peerCount = 0
  for f in futs:
    if f.completed() and f.value().isOk():
      inc peerCount # only count successful offers

  peerCount

proc neighborhoodGossip*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    content: seq[seq[byte]],
    enableNodeLookup = false,
): Future[int] {.async: (raises: [CancelledError]).} =
  ## Run neighborhood gossip for provided content.
  ## Returns the number of peers to which content was attempted to be gossiped.
  ## When enableNodeLookup is true then if the local routing table doesn't
  ## have enough nodes with a radius in range of the content then a node lookup
  ## is used to find nodes from the network. Note: For this part to work efficiently
  ## the radius cache should be relatively large (ideally equal to the total number
  ## of nodes in the network) to reduce the number of pings required to populate
  ## the cache over time as old content is removed when the cache is full.
  if content.len() == 0:
    return 0

  var contentList = List[ContentKV, contentKeysLimit].init(@[])
  for i, contentItem in content:
    let contentKV = ContentKV(contentKey: contentKeys[i], content: contentItem)
    discard contentList.add(contentKV)

  # Just taking the first content item as target id.
  # TODO: come up with something better?
  let contentId = p.toContentId(contentList[0].contentKey).valueOr:
    return 0

  # For selecting the closest nodes to whom to gossip the content a mixed
  # approach is taken:
  # 1. Select the closest neighbours in the routing table.
  # 2. Shuffle the selected nodes to randomize the gossip process so that we
  # don't always offer to the same closest nodes.
  # 3. Check if the radius is known for these these nodes and whether they are
  # in range of the content to be offered.
  # 4. If more than n (= maxGossipNodes) nodes are in range, offer these nodes
  # the content (maxed out at n).
  # 5. If less than n nodes are in range, do a node lookup, and offer the nodes
  # returned from the lookup the content (max nodes set at 8).
  #
  # This should give a bigger rate of success and avoid the data being stopped
  # in its propagation than when looking only for nodes in the own routing
  # table, but at the same time avoid unnecessary node lookups.
  # It might still cause issues in data getting propagated in a wider id range.

  var excluding: HashSet[NodeId]
  if srcNodeId.isSome():
    excluding.incl(srcNodeId.get())

  var closestLocalNodes =
    p.neighboursInRange(contentId, BUCKET_SIZE, seenOnly = true, excluding)

  # Shuffling the order of the nodes in order to not always hit the same node
  # first for the same request.
  p.baseProtocol.rng[].shuffle(closestLocalNodes)

  var offers = newSeqOfCap[OfferRequest](p.config.maxGossipNodes)

  if not enableNodeLookup or closestLocalNodes.len() >= p.config.maxGossipNodes:
    # use local nodes for gossip
    portal_gossip_without_lookup.inc(labelValues = [$p.protocolId])

    for node in closestLocalNodes:
      let req = OfferRequest(dst: node, kind: Direct, contentList: contentList)
      offers.add(req)

      if offers.len() >= p.config.maxGossipNodes:
        break
  else: # use looked up nodes for gossip
    portal_gossip_with_lookup.inc(labelValues = [$p.protocolId])

    let closestNodes = await p.lookup(NodeId(contentId))

    for node in closestNodes:
      if p.radiusCache.get(node.id).isNone():
        # Send ping to add the node to the radius cache
        (await p.ping(node)).isOkOr:
          continue

      let radius = p.radiusCache.get(node.id).valueOr:
        continue

      # Only send offers to nodes for which the content is in range of their radius
      if p.inRange(node.id, radius, contentId):
        let req = OfferRequest(dst: node, kind: Direct, contentList: contentList)
        offers.add(req)

        if offers.len() >= p.config.maxGossipNodes:
          break

  await p.offerBatchGetPeerCount(offers)

proc neighborhoodGossipDiscardPeers*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    content: seq[seq[byte]],
    enableNodeLookup = false,
): Future[void] {.async: (raises: [CancelledError]).} =
  discard await p.neighborhoodGossip(srcNodeId, contentKeys, content, enableNodeLookup)

proc randomGossip*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    content: seq[seq[byte]],
): Future[int] {.async: (raises: [CancelledError]).} =
  ## Run random gossip for provided content.
  ## Returns the number of peers to which content was attempted to be gossiped.
  if content.len() == 0:
    return 0

  var contentList = List[ContentKV, contentKeysLimit].init(@[])
  for i, contentItem in content:
    let contentKV = ContentKV(contentKey: contentKeys[i], content: contentItem)
    discard contentList.add(contentKV)

  let
    nodes = p.routingTable.randomNodes(p.config.maxGossipNodes)
    offers = nodes.mapIt(OfferRequest(dst: it, kind: Direct, contentList: contentList))

  await p.offerBatchGetPeerCount(offers)

proc randomGossipDiscardPeers*(
    p: PortalProtocol,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    content: seq[seq[byte]],
): Future[void] {.async: (raises: [CancelledError]).} =
  discard await p.randomGossip(srcNodeId, contentKeys, content)

proc storeContent*(
    p: PortalProtocol,
    contentKey: ContentKeyByteList,
    contentId: ContentId,
    content: seq[byte],
    cacheContent = false,
    cacheOffer = false,
): bool {.discardable.} =
  if cacheContent and not p.config.disableContentCache:
    # We cache content regardless of whether it is in our radius or not
    p.contentCache.put(contentId, content)

  # Always re-check that the key is still in the node range to make sure only
  # content in range is stored.
  if p.inRange(contentId):
    let dbPruned = p.dbPut(contentKey, contentId, content)
    if dbPruned:
      # invalidate all cached content incase it was removed from the database
      # during pruning
      p.offerCache = OfferCache.init(p.offerCache.capacity)

    if cacheOffer and not p.config.disableOfferCache:
      p.offerCache.put(contentId, true)

    true
  else:
    false

proc getLocalContent*(
    p: PortalProtocol, contentKey: ContentKeyByteList, contentId: ContentId
): Opt[seq[byte]] =
  # The cache can contain content that is not in our radius
  let maybeContent = p.contentCache.get(contentId)
  if maybeContent.isSome():
    portal_content_cache_hits.inc(labelValues = [$p.protocolId])
    return maybeContent

  portal_content_cache_misses.inc(labelValues = [$p.protocolId])

  # Check first if content is in range, as this is a cheaper operation
  # than the database lookup.
  if p.inRange(contentId):
    p.dbGet(contentKey, contentId)
  else:
    Opt.none(seq[byte])

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
      debug "Added bootstrap node", uri = toURI(record), protocolId = p.protocolId
    else:
      error "Bootstrap node could not be added",
        uri = toURI(record), protocolId = p.protocolId

proc populateTable(p: PortalProtocol) {.async: (raises: [CancelledError]).} =
  ## Do a set of initial lookups to quickly populate the table.
  # start with a self target query (neighbour nodes)
  logScope:
    protocolId = p.protocolId

  let selfQuery = await p.query(p.localNode.id)
  trace "Discovered nodes in self target query", nodes = selfQuery.len

  for i in 0 ..< initialLookups:
    let randomQuery = await p.queryRandom()
    trace "Discovered nodes in random target query", nodes = randomQuery.len

  debug "Total nodes in routing table after populate", total = p.routingTable.len()

proc revalidateNode*(p: PortalProtocol, n: Node) {.async: (raises: [CancelledError]).} =
  let pong = await p.ping(n)

  if pong.isOk():
    let (enrSeq, _, _) = pong.get()
    if enrSeq > n.record.seqNum:
      # Request new ENR
      let nodesMessage = await p.findNodes(n, @[0'u16])
      if nodesMessage.isOk():
        let nodes = nodesMessage.get()
        if nodes.len > 0: # Normally a node should only return 1 record actually
          discard p.addNode(nodes[0])

proc getNodeForRevalidation(p: PortalProtocol): Opt[Node] =
  let node = p.routingTable.nodeToRevalidate()
  if node.isNil:
    # This should not occur except for when the RT is empty
    return Opt.none(Node)

  let now = now(chronos.Moment)
  let timestamp = p.pingTimings.getOrDefault(node.id, Moment.init(0'i64, Second))

  if (timestamp + revalidationTimeout) < now:
    Opt.some(node)
  else:
    Opt.none(Node)

proc revalidateLoop(p: PortalProtocol) {.async: (raises: []).} =
  ## Loop which revalidates the nodes in the routing table by sending the ping
  ## message.
  try:
    while true:
      await sleepAsync(milliseconds(p.baseProtocol.rng[].rand(revalidateMax)))
      let n = getNodeForRevalidation(p)
      if n.isSome:
        asyncSpawn p.revalidateNode(n.get())
  except CancelledError:
    trace "revalidateLoop canceled"

proc refreshLoop(p: PortalProtocol) {.async: (raises: []).} =
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

      # Remove the expired bans from routing table to limit memory usage
      p.routingTable.cleanupExpiredBans()

      await sleepAsync(refreshInterval)
  except CancelledError:
    trace "refreshLoop canceled"

proc start*(p: PortalProtocol) =
  p.refreshLoop = refreshLoop(p)
  p.revalidateLoop = revalidateLoop(p)

proc stop*(p: PortalProtocol) {.async: (raises: []).} =
  var futures: seq[Future[void]]

  if not p.revalidateLoop.isNil():
    futures.add(p.revalidateLoop.cancelAndWait())
  if not p.refreshLoop.isNil():
    futures.add(p.refreshLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  p.revalidateLoop = nil
  p.refreshLoop = nil

proc resolve*(
    p: PortalProtocol, id: NodeId
): Future[Opt[Node]] {.async: (raises: [CancelledError]).} =
  ## Resolve a `Node` based on provided `NodeId`.
  ##
  ## This will first look in the own routing table. If the node is known, it
  ## will try to contact if for newer information. If node is not known or it
  ## does not reply, a lookup is done to see if it can find a (newer) record of
  ## the node on the network.
  if id == p.localNode.id:
    return Opt.some(p.localNode)

  # No point in trying to resolve a banned node because it won't exist in the
  # routing table and it will be filtered out of any respones in the lookup call
  if p.isBanned(id):
    debug "Not resolving banned node", nodeId = id
    return Opt.none(Node)

  let node = p.getNode(id)
  if node.isSome():
    let nodesMessage = await p.findNodes(node.get(), @[0'u16])
    # TODO: Handle failures better. E.g. stop on different failures than timeout
    if nodesMessage.isOk() and nodesMessage[].len > 0:
      return Opt.some(nodesMessage[][0])

  let discovered = await p.lookup(id)
  for n in discovered:
    if n.id == id:
      if node.isSome() and node.get().record.seqNum >= n.record.seqNum:
        return node
      else:
        return Opt.some(n)

  return node
