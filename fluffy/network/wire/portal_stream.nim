# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets],
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
  ContentRequest = object
    connectionId: uint16
    nodeId: NodeId
    contentId: ContentId
    content: seq[byte]
    timeout: Moment

  ContentOffer = object
    connectionId: uint16
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
    contentRequests: seq[ContentRequest]
    contentOffers: seq[ContentOffer]
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

  var i = 0
  while i < stream.contentRequests.len():
    let request = stream.contentRequests[i]
    if request.timeout <= now:
      stream.removePendingTransfer(request.nodeId, request.contentId)
      stream.contentRequests.del(i)
    else:
      inc i

proc pruneAllowedOfferConnections*(stream: PortalStream) =
  # Prune offers that didn't receive a connection request
  # before `connectionTimeout`.
  let now = Moment.now()

  var i = 0
  while i < stream.contentOffers.len():
    let offer = stream.contentOffers[i]
    if offer.timeout <= now:
      for contentId in offer.contentIds:
        stream.removePendingTransfer(offer.nodeId, contentId)
      stream.contentOffers.del(i)
    else:
      inc i

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
  let id = uint16.fromBytesBE(connectionId)

  debug "Register new incoming offer", contentKeys

  let contentOffer = ContentOffer(
    connectionId: id,
    nodeId: nodeId,
    contentIds: contentIds,
    contentKeys: contentKeys,
    timeout: Moment.now() + stream.connectionTimeout,
  )
  stream.contentOffers.add(contentOffer)

  return connectionId

proc addContentRequest*(
    stream: PortalStream, nodeId: NodeId, contentId: ContentId, content: seq[byte]
): Bytes2 =
  # TODO: Should we check if `NodeId` & `connectionId` combo already exists?
  # What happens if we get duplicates?
  var connectionId: Bytes2
  stream.rng[].generate(connectionId)

  # uTP protocol uses BE for all values in the header, incl. connection id.
  let id = uint16.fromBytesBE(connectionId)
  let contentRequest = ContentRequest(
    connectionId: id,
    nodeId: nodeId,
    contentId: contentId,
    content: content,
    timeout: Moment.now() + stream.connectionTimeout,
  )
  stream.contentRequests.add(contentRequest)

  return connectionId

proc connectTo*(
    stream: PortalStream, nodeAddress: NodeAddress, connectionId: uint16
): Future[Result[UtpSocket[NodeAddress], string]] {.async: (raises: [CancelledError]).} =
  let connectRes = await stream.transport.connectTo(nodeAddress, connectionId)
  if connectRes.isErr():
    case connectRes.error
    of SocketAlreadyExists:
      # This means that there is already a socket to this nodeAddress with given
      # connection id. This means that a peer sent us a connection id which is
      # already in use. The connection is failed and an error returned.
      let msg =
        "Socket to " & $nodeAddress & "with connection id: " & $connectionId &
        " already exists"
      return err(msg)
    of ConnectionTimedOut:
      # A time-out here means that a uTP SYN packet was re-sent 3 times and
      # failed to be acked. This should be enough of indication that the
      # remote host is not reachable and no new connections are attempted.
      let msg = "uTP timeout while trying to connect to " & $nodeAddress
      return err(msg)
  else:
    return ok(connectRes.get())

proc writeContentRequest(
    socket: UtpSocket[NodeAddress], stream: PortalStream, request: ContentRequest
) {.async: (raises: [CancelledError]).} =
  let dataWritten = await socket.write(request.content)
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

proc readContentValue(
    socket: UtpSocket[NodeAddress]
): Future[Result[seq[byte], string]] {.async: (raises: [CancelledError]).} =
  let len = (await socket.readVarint()).valueOr:
    return err($error)

  let contentValue = await socket.read(len)
  if contentValue.len() == len.int:
    ok(contentValue)
  else:
    err("Content value length mismatch")

proc readContentOffer(
    socket: UtpSocket[NodeAddress], stream: PortalStream, offer: ContentOffer
) {.async: (raises: [CancelledError]).} =
  # Read number of content values according to amount of ContentKeys accepted.
  # This will either end with a FIN, or because the read action times out or
  # because the number of expected values was read (if this happens and no FIN
  # was received yet, a FIN will be send from this side).
  # None of this means that the contentValues are valid, further validation is
  # required.
  # Socket will be closed when this call ends.

  # TODO: Currently reading from the socket one value at a time, and validating
  # values at later time. Uncertain what is best approach here (mostly from a
  # security PoV), e.g. other options such as reading all content from socket at
  # once, then processing the individual content values. Or reading and
  # validating one per time.
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
      # Read timed out, stop further reading, but still process data received
      # so far.
      debug "Reading data from socket timed out, content offer failed",
        contentKeys = offer.contentKeys
      break

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
    connectionTimeout: connectionTimeout,
    contentReadTimeout: contentReadTimeout,
    pendingTransfers: newTable[NodeId, HashSet[ContentId]](),
    contentQueue: contentQueue,
    rng: rng,
  )

  stream

proc allowedConnection(
    stream: PortalStream, address: NodeAddress, connectionId: uint16
): bool =
  return
    stream.contentRequests.any(
      proc(x: ContentRequest): bool =
        x.connectionId == connectionId and x.nodeId == address.nodeId
    ) or
    stream.contentOffers.any(
      proc(x: ContentOffer): bool =
        x.connectionId == connectionId and x.nodeId == address.nodeId
    )

proc handleIncomingConnection(
    server: UtpRouter[NodeAddress], socket: UtpSocket[NodeAddress]
): Future[void] {.async: (raw: true, raises: []).} =
  let manager = getUserData[NodeAddress, StreamManager](server)

  for stream in manager.streams:
    # Note: Connection id of uTP SYN is different from other packets, it is
    # actually the peers `send_conn_id`, opposed to `receive_conn_id` for all
    # other packets.
    for i, request in stream.contentRequests:
      if request.connectionId == socket.connectionId and
          request.nodeId == socket.remoteAddress.nodeId:
        let fut = socket.writeContentRequest(stream, request)

        stream.removePendingTransfer(request.nodeId, request.contentId)
        stream.contentRequests.del(i)
        return noCancel(fut)

    for i, offer in stream.contentOffers:
      if offer.connectionId == socket.connectionId and
          offer.nodeId == socket.remoteAddress.nodeId:
        let fut = socket.readContentOffer(stream, offer)

        for contentId in offer.contentIds:
          stream.removePendingTransfer(offer.nodeId, contentId)
        stream.contentOffers.del(i)
        return noCancel(fut)

  # TODO: Is there a scenario where this can happen,
  # considering `allowRegisteredIdCallback`? If not, doAssert?
  var fut = newFuture[void]("fluffy.AcceptConnectionCallback")
  fut.complete()
  return fut

proc allowIncomingConnection(
    r: UtpRouter[NodeAddress], remoteAddress: NodeAddress, connectionId: uint16
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
