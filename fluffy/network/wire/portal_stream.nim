# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sets,
  chronos,
  stew/[byteutils, leb128, endians2],
  chronicles,
  eth/utp/utp_discv5_protocol,
  # even though utp_discv5_protocol exports this, import is still needed,
  # perhaps protocol.Protocol type of usage?
  eth/p2p/discoveryv5/protocol,
  ./messages

export utp_discv5_protocol

logScope:
  topics = "portal_stream"

const
  utpProtocolId = "utp".toBytes()
  defaultConnectionTimeout = 15.seconds
  defaultContentReadTimeout = 60.seconds

  # TalkReq message is used as transport for uTP. It is assumed here that Portal
  # protocol messages were exchanged before sending uTP over discv5 data. This
  # means that a session is established and that the discv5 messages send are
  # discv5 ordinary message packets, for which below calculation applies.
  talkReqOverhead = getTalkReqOverhead(utpProtocolId)
  utpHeaderOverhead = 20
  maxUtpPayloadSize = maxDiscv5PacketSize - talkReqOverhead - utpHeaderOverhead
  maxPendingTransfersPerPeer = 128

type
  ConnectionId* = uint16

  ContentRequest = object
    nodeId: NodeId
    contentId: ContentId
    content: seq[byte]
    timeout: Moment
    version: uint8

  ContentOffer = object
    nodeId: NodeId
    contentIds: seq[ContentId]
    contentKeys: ContentKeysList
    timeout: Moment

  PortalStream* = ref object
    transport: UtpDiscv5Protocol
    # TODO:
    # Decide on what's the better collection to use and set some limits in them
    # on how many uTP transfers allowed to happen concurrently.
    # Either set some limit, and drop whatever comes next. Unsure how to
    # communicate that with the peer however. Or have some more async waiting
    # until a spot becomes free, like with an AsyncQueue. Although the latter
    # probably can not be used here directly. This system however does needs
    # some agreement on timeout values of how long a uTP socket may be
    # "listening" before it times out because of inactivity.
    # Or, depending on the direction, it might also depend on the time out
    # values of the discovery v5 talkresp message.
    # TODO: Should the content key also be stored to be able to validate the
    # received data?
    contentRequests: TableRef[ConnectionId, ContentRequest]
    contentOffers: TableRef[ConnectionId, ContentOffer]
    connectionTimeout: Duration
    contentReadTimeout*: Duration
    rng: ref HmacDrbgContext
    pendingTransfers: TableRef[NodeId, HashSet[ContentId]]
    contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]

  StreamManager* = ref object
    transport: UtpDiscv5Protocol
    streams: seq[PortalStream]
    rng: ref HmacDrbgContext

proc canAddPendingTransfer(
    transfers: TableRef[NodeId, HashSet[ContentId]],
    nodeId: NodeId,
    contentId: ContentId,
    limit: int,
): bool =
  if not transfers.contains(nodeId):
    return true

  try:
    let contentIds = transfers[nodeId]
    if (contentIds.len() < limit) and not contentIds.contains(contentId):
      return true
    else:
      debug "Pending transfer limit reached for peer", nodeId, contentId
      return false
  except KeyError as e:
    raiseAssert(e.msg)

proc addPendingTransfer(
    transfers: TableRef[NodeId, HashSet[ContentId]],
    nodeId: NodeId,
    contentId: ContentId,
) =
  if transfers.contains(nodeId):
    try:
      transfers[nodeId].incl(contentId)
    except KeyError as e:
      raiseAssert(e.msg)
  else:
    var contentIds = initHashSet[ContentId]()
    contentIds.incl(contentId)
    transfers[nodeId] = contentIds

proc removePendingTransfer(
    transfers: TableRef[NodeId, HashSet[ContentId]],
    nodeId: NodeId,
    contentId: ContentId,
) =
  doAssert transfers.contains(nodeId)

  try:
    transfers[nodeId].excl(contentId)

    if transfers[nodeId].len() == 0:
      transfers.del(nodeId)
  except KeyError as e:
    raiseAssert(e.msg)

template canAddPendingTransfer*(
    stream: PortalStream, nodeId: NodeId, contentId: ContentId
): bool =
  stream.pendingTransfers.canAddPendingTransfer(
    srcId, contentId, maxPendingTransfersPerPeer
  )

template addPendingTransfer*(
    stream: PortalStream, nodeId: NodeId, contentId: ContentId
) =
  addPendingTransfer(stream.pendingTransfers, nodeId, contentId)

template removePendingTransfer*(
    stream: PortalStream, nodeId: NodeId, contentId: ContentId
) =
  removePendingTransfer(stream.pendingTransfers, nodeId, contentId)

proc pruneAllowedRequestConnections*(stream: PortalStream) =
  # Prune requests that didn't receive a connection request
  # before `connectionTimeout`.
  let now = Moment.now()

  var connectionIdsToPrune = newSeq[ConnectionId]()
  for connectionId, request in stream.contentRequests:
    if request.timeout <= now:
      stream.removePendingTransfer(request.nodeId, request.contentId)
      connectionIdsToPrune.add(connectionId)

  for connectionId in connectionIdsToPrune:
    stream.contentRequests.del(connectionId)

proc pruneAllowedOfferConnections*(stream: PortalStream) =
  # Prune offers that didn't receive a connection request
  # before `connectionTimeout`.
  let now = Moment.now()

  var connectionIdsToPrune = newSeq[ConnectionId]()
  for connectionId, offer in stream.contentOffers:
    if offer.timeout <= now:
      for contentId in offer.contentIds:
        stream.removePendingTransfer(offer.nodeId, contentId)
      connectionIdsToPrune.add(connectionId)

  for connectionId in connectionIdsToPrune:
    stream.contentOffers.del(connectionId)

proc addContentOffer*(
    stream: PortalStream,
    nodeId: NodeId,
    contentKeys: ContentKeysList,
    contentIds: seq[ContentId],
): Bytes2 =
  # TODO: Should we check if `NodeId` & `connectionId` combo already exists?
  # What happens if we get duplicates?
  var connectionId: Bytes2
  stream.rng[].generate(connectionId)

  # uTP protocol uses BE for all values in the header, incl. connection id.
  var id = ConnectionId.fromBytesBE(connectionId)

  # Generate a new id if already existing to avoid using a duplicate
  if stream.contentOffers.contains(id):
    stream.rng[].generate(connectionId)
    id = ConnectionId.fromBytesBE(connectionId)

  debug "Register new incoming offer", contentKeys

  let contentOffer = ContentOffer(
    nodeId: nodeId,
    contentIds: contentIds,
    contentKeys: contentKeys,
    timeout: Moment.now() + stream.connectionTimeout,
  )
  stream.contentOffers[id] = contentOffer

  return connectionId

proc addContentRequest*(
    stream: PortalStream,
    nodeId: NodeId,
    contentId: ContentId,
    content: seq[byte],
    version: uint8,
): Bytes2 =
  # TODO: Should we check if `NodeId` & `connectionId` combo already exists?
  # What happens if we get duplicates?
  var connectionId: Bytes2
  stream.rng[].generate(connectionId)

  # uTP protocol uses BE for all values in the header, incl. connection id.
  var id = ConnectionId.fromBytesBE(connectionId)

  # Generate a new id if already existing to avoid using a duplicate
  if stream.contentRequests.contains(id):
    stream.rng[].generate(connectionId)
    id = ConnectionId.fromBytesBE(connectionId)

  let contentRequest = ContentRequest(
    nodeId: nodeId,
    contentId: contentId,
    content: content,
    timeout: Moment.now() + stream.connectionTimeout,
    version: version,
  )
  stream.contentRequests[id] = contentRequest

  return connectionId

proc connectTo*(
    stream: PortalStream, nodeAddress: NodeAddress, connectionId: ConnectionId
): Future[Result[UtpSocket[NodeAddress], string]] {.async: (raises: [CancelledError]).} =
  let connectRes = await stream.transport.connectTo(nodeAddress, connectionId)
  if connectRes.isErr():
    case connectRes.error
    of SocketAlreadyExists:
      # There is already a socket to this nodeAddress with given connection id.
      # This means that a peer sent a connection id which is already in use.
      err(
        "Socket to " & $nodeAddress & " with connection id " & $connectionId &
          " already exists"
      )
    of ConnectionTimedOut:
      # A time-out here means that a uTP SYN packet was sent 3 times and failed
      # to be acked. This should be enough of indication that the remote host is
      # not reachable and no new connections are attempted.
      err("uTP connection timeout when connecting to node: " & $nodeAddress)
  else:
    ok(connectRes.value())

template lenu32*(x: untyped): untyped =
  uint32(len(x))

proc writeContentRequestV0(
    socket: UtpSocket[NodeAddress], stream: PortalStream, request: ContentRequest
) {.async: (raises: [CancelledError]).} =
  let dataWritten = await socket.write(request.content)
  if dataWritten.isErr():
    debug "Error writing requested data", error = dataWritten.error

  await socket.closeWait()

proc writeContentRequestV1(
    socket: UtpSocket[NodeAddress], stream: PortalStream, request: ContentRequest
) {.async: (raises: [CancelledError]).} =
  var output = memoryOutput()
  try:
    output.write(toBytes(request.content.lenu32, Leb128).toOpenArray())
    output.write(request.content)
  except IOError as e:
    # This should not happen in case of in-memory streams
    raiseAssert e.msg

  let dataWritten = await socket.write(output.getOutput)
  if dataWritten.isErr():
    debug "Error writing requested data", error = dataWritten.error

  await socket.closeWait()

proc readVarint(
    socket: UtpSocket[NodeAddress]
): Future[Result[uint32, string]] {.async: (raises: [CancelledError]).} =
  var buffer: array[5, byte]

  for i in 0 ..< len(buffer):
    let dataRead = await socket.read(1)
    if dataRead.len() == 0:
      return err("No data read")

    buffer[i] = dataRead[0]

    let (lenU32, bytesRead) = fromBytes(uint32, buffer.toOpenArray(0, i), Leb128)
    if bytesRead > 0:
      return ok(lenU32)
    elif bytesRead == 0:
      continue
    else:
      return err("Failed to read varint")

proc readContentValue*(
    socket: UtpSocket[NodeAddress]
): Future[Result[seq[byte], string]] {.async: (raises: [CancelledError]).} =
  let len = (await socket.readVarint()).valueOr:
    return err($error)

  let contentValue = await socket.read(len)
  if contentValue.len() == len.int:
    ok(contentValue)
  else:
    err("Content value length mismatch")

proc readContentValueNoResult*(
    socket: UtpSocket[NodeAddress]
): Future[seq[byte]] {.async: (raises: [CancelledError]).} =
  let len = (await socket.readVarint()).valueOr:
    return @[]
  let contentValue = await socket.read(len)
  if contentValue.len() == len.int:
    contentValue
  else:
    @[]

proc readContentOffer(
    socket: UtpSocket[NodeAddress], stream: PortalStream, offer: ContentOffer
) {.async: (raises: [CancelledError]).} =
  # Read number of content values according to amount of ContentKeys accepted.
  # This will either end with a FIN, or because the read action times out or
  # because the number of expected values was read (if this happens and no FIN
  # is received eventually, the socket will just get destroyed).
  # None of this means that the contentValues are valid, further validation is
  # required. This call deals with cleaning up the socket.

  # Content items are read from the socket and added to a queue for later
  # validation. Validating the content item immediatly would likely result in
  # timeouts of the rest of the content transmitted.
  let amount = offer.contentKeys.len()

  var contentValues: seq[seq[byte]]
  for i in 0 ..< amount:
    let contentValueFut = socket.readContentValue()
    if await contentValueFut.withTimeout(stream.contentReadTimeout):
      let contentValue = await contentValueFut

      if contentValue.isOk():
        contentValues.add(contentValue.get())
      else:
        # Invalid data, stop reading content, but still process data received
        # so far.
        debug "Reading content value failed, content offer failed",
          contentKeys = offer.contentKeys, error = contentValue.error
        break
    else:
      # Read timed out, stop further reading and discard the data received so
      # far as it will be incomplete.
      debug "Reading data from socket timed out, content offer failed",
        contentKeys = offer.contentKeys
      # Still closing the socket (= sending FIN) but not waiting here for its
      # ACK however, so no `closeWait`. Underneath the socket will still wait
      # for the FIN-ACK (or timeout) before it destroys the socket.
      socket.close()
      return

  if socket.atEof():
    # Destroy socket and not closing as we already received FIN. Closing would
    # send also a FIN from our side, see also:
    # https://github.com/status-im/nim-eth/blob/b2dab4be0839c95ca2564df9eacf81995bf57802/eth/utp/utp_socket.nim#L1223
    await socket.destroyWait()
  else:
    # This means FIN didn't arrive yet, perhaps it got dropped but it might also
    # be still in flight.
    #
    # uTP has one-way FIN + FIN-ACK to destroy the connection. The stream
    # already has the information from the application layer to know that all
    # required data was received. But not sending a FIN from our side anyhow as
    # there is probably one from the other side in flight.
    # Sending a FIN from our side turns out to not to improve the speed of
    # disconnecting as other implementations seems to not like the situation
    # of receiving our FIN before our FIN-ACK.
    # We do however put a limited timeout on the receival of the FIN and destroy
    # the socket otherwise.
    proc delayedDestroy(
        socket: UtpSocket[NodeAddress], delay: Duration
    ) {.async: (raises: [CancelledError]).} =
      await sleepAsync(delay)
      await socket.destroyWait()

    asyncSpawn socket.delayedDestroy(4.seconds)

  # TODO: This could currently create a backlog of content values to be validated
  # as `AcceptConnectionCallback` is `asyncSpawn`'ed and there are no limits
  # on the `contentOffers`. Might move the queue to before the reading of the
  # socket, and let the specific networks handle that.
  await stream.contentQueue.put(
    (Opt.some(offer.nodeId), offer.contentKeys, contentValues)
  )

proc new(
    T: type PortalStream,
    transport: UtpDiscv5Protocol,
    contentQueue: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])],
    connectionTimeout: Duration,
    contentReadTimeout: Duration,
    rng: ref HmacDrbgContext,
): T =
  let stream = PortalStream(
    transport: transport,
    contentRequests: newTable[ConnectionId, ContentRequest](),
    contentOffers: newTable[ConnectionId, ContentOffer](),
    connectionTimeout: connectionTimeout,
    contentReadTimeout: contentReadTimeout,
    pendingTransfers: newTable[NodeId, HashSet[ContentId]](),
    contentQueue: contentQueue,
    rng: rng,
  )

  stream

proc allowedConnection(
    stream: PortalStream, address: NodeAddress, connectionId: ConnectionId
): bool =
  if stream.contentRequests.contains(connectionId) and
      stream.contentRequests.getOrDefault(connectionId).nodeId == address.nodeId:
    return true

  if stream.contentOffers.contains(connectionId) and
      stream.contentOffers.getOrDefault(connectionId).nodeId == address.nodeId:
    return true

  return false

proc handleIncomingConnection(
    server: UtpRouter[NodeAddress], socket: UtpSocket[NodeAddress]
): Future[void] {.async: (raw: true, raises: []).} =
  let manager = getUserData[NodeAddress, StreamManager](server)

  for stream in manager.streams:
    # Note: Connection id of uTP SYN is different from other packets, it is
    # actually the peers `send_conn_id`, opposed to `receive_conn_id` for all
    # other packets.

    if stream.contentRequests.contains(socket.connectionId):
      let request = stream.contentRequests.getOrDefault(socket.connectionId)
      if request.nodeId == socket.remoteAddress.nodeId:
        let fut =
          if request.version >= 1:
            socket.writeContentRequestV1(stream, request)
          else:
            socket.writeContentRequestV0(stream, request)

        stream.removePendingTransfer(request.nodeId, request.contentId)
        stream.contentRequests.del(socket.connectionId)
        return noCancel(fut)

    if stream.contentOffers.contains(socket.connectionId):
      let offer = stream.contentOffers.getOrDefault(socket.connectionId)
      if offer.nodeId == socket.remoteAddress.nodeId:
        let fut = socket.readContentOffer(stream, offer)

        for contentId in offer.contentIds:
          stream.removePendingTransfer(offer.nodeId, contentId)
        stream.contentOffers.del(socket.connectionId)
        return noCancel(fut)

  # TODO: Is there a scenario where this can happen,
  # considering `allowRegisteredIdCallback`? If not, doAssert?
  var fut = newFuture[void]("fluffy.AcceptConnectionCallback")
  fut.complete()
  return fut

proc allowIncomingConnection(
    r: UtpRouter[NodeAddress], remoteAddress: NodeAddress, connectionId: ConnectionId
): bool =
  let manager = getUserData[NodeAddress, StreamManager](r)
  for stream in manager.streams:
    # stream.pruneAllowedConnections()
    if allowedConnection(stream, remoteAddress, connectionId):
      return true

proc new*(T: type StreamManager, d: protocol.Protocol): T =
  let
    socketConfig = SocketConfig.init(
      # Setting to none means that incoming sockets are in Connected state, which
      # means they can send and receive data.
      incomingSocketReceiveTimeout = none(Duration),
      payloadSize = uint32(maxUtpPayloadSize),
    )
    manager = StreamManager(streams: @[], rng: d.rng)
    utpOverDiscV5Protocol = UtpDiscv5Protocol.new(
      d, utpProtocolId, handleIncomingConnection, manager, allowIncomingConnection,
      socketConfig,
    )

  manager.transport = utpOverDiscV5Protocol

  return manager

proc registerNewStream*(
    m: StreamManager,
    contentQueue: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])],
    connectionTimeout = defaultConnectionTimeout,
    contentReadTimeout = defaultContentReadTimeout,
): PortalStream =
  let s = PortalStream.new(
    m.transport, contentQueue, connectionTimeout, contentReadTimeout, m.rng
  )

  m.streams.add(s)

  return s
