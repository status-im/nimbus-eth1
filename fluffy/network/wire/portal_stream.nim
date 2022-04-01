# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  chronos, stew/byteutils, chronicles,
  eth/utp/utp_discv5_protocol,
  # even though utp_discv5_protocol exports this, import is still needed,
  # perhaps protocol.Protocol type of usage?
  eth/p2p/discoveryv5/protocol,
  ./messages

export utp_discv5_protocol

const
  utpProtocolId* = "utp".toBytes()
  defaultConnectionTimeout = 5.seconds
  defaultReadTimeout = 2.seconds

type
  ContentRequest = object
    connectionId: uint16
    nodeId: NodeId
    content: seq[byte]
    timeout: Moment

  ContentOffer = object
    connectionId: uint16
    nodeId: NodeId
    contentKeys: ContentKeysList
    timeout: Moment

  ContentHandlerCallback* = proc(
    stream: PortalStream, contentKeys: ContentKeysList, content: seq[byte])
    {.gcsafe, raises: [Defect].}

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
    readTimeout*: Duration
    rng: ref BrHmacDrbgContext
    udata: pointer
    contentHandler: ContentHandlerCallback

proc getUserData*[T](stream: PortalStream): T =
  ## Obtain user data stored in ``stream`` object.
  cast[T](stream.udata)

proc addContentOffer*(
    stream: PortalStream, nodeId: NodeId, contentKeys: ContentKeysList): Bytes2 =
  var connectionId: Bytes2
  brHmacDrbgGenerate(stream.rng[], connectionId)

  # uTP protocol uses BE for all values in the header, incl. connection id.
  let id = uint16.fromBytesBE(connectionId)
  let contentOffer = ContentOffer(
    connectionId: id,
    nodeId: nodeId,
    contentKeys: contentKeys,
    timeout: Moment.now() + stream.connectionTimeout)
  stream.contentOffers.add(contentOffer)

  return connectionId

proc addContentRequest*(
    stream: PortalStream, nodeId: NodeId, content: seq[byte]): Bytes2 =
  var connectionId: Bytes2
  brHmacDrbgGenerate(stream.rng[], connectionId)

  # uTP protocol uses BE for all values in the header, incl. connection id.
  let id = uint16.fromBytesBE(connectionId)
  let contentRequest = ContentRequest(
    connectionId: id,
    nodeId: nodeId,
    content: content,
    timeout: Moment.now() + stream.connectionTimeout)
  stream.contentRequests.add(contentRequest)

  return connectionId

proc connectTo*(
  stream: PortalStream,
  nodeAddress: NodeAddress,
  connectionId: uint16): Future[Result[UtpSocket[NodeAddress], string]] {.async.} =
  let socketRes = await stream.transport.connectTo(nodeAddress, connectionId)

  if socketRes.isErr():
    case socketRes.error.kind
    of SocketAlreadyExists:
      # This error means that there is already socket to this nodeAddress with given
      # connection id, in our use case it most probably means that other side sent us
      # connection id which is already used.
      # For now we just fail connection and return an error. Another strategy to consider
      # would be to check what is the connection status, and then re-use it, or
      # close it and retry connection.
      let msg = "Socket to " & $nodeAddress & "with connection id: " & $connectionId & " already exists"
      return err(msg)
    of ConnectionTimedOut:
      # Another strategy for handling this error would be to retry connecting a few times
      # before giving up. But we know (as we control the uTP impl) that this error will only
      # be returned when a SYN packet was re-sent 3 times and failed to be acked. This
      # should be enough for us to known that the remote host is not reachable.
      let msg = "uTP timeout while trying to connect to " & $nodeAddress
      return err(msg)

  let socket = socketRes.get()
  return ok(socket)

proc writeAndClose(
    socket: UtpSocket[NodeAddress], stream: PortalStream,
    request: ContentRequest) {.async.} =
  let dataWritten =  await socket.write(request.content)
  if dataWritten.isErr():
    debug "Error writing requested data", error = dataWritten.error

  await socket.closeWait()

proc readAndClose(
    socket: UtpSocket[NodeAddress], stream: PortalStream,
    offer: ContentOffer) {.async.} =
  # Read all bytes from the socket
  # This will either end with a FIN, or because the read action times out.
  # A FIN does not necessarily mean that the data read is complete. Further
  # validation is required, using a length prefix here might be beneficial for
  # this.
  # TODO: Should also limit the amount of data to read and/or total time.
  var readData = socket.read()
  if await readData.withTimeout(stream.readTimeout):
    let content = readData.read
    if not stream.contentHandler.isNil():
      stream.contentHandler(stream, offer.contentKeys, content)

    # Destroy socket and not closing as we already received. Closing would send
    # also a FIN from our side, see also:
    # https://github.com/status-im/nim-eth/blob/b2dab4be0839c95ca2564df9eacf81995bf57802/eth/utp/utp_socket.nim#L1223
    await socket.destroyWait()
  else:
    debug "Reading data from socket timed out, content request failed"
    # Even though reading timed out, lets be nice and still send a FIN.
    # Not waiting here for its ACK however, so no `closeWait`
    socket.close()

proc new*(
    T: type PortalStream,
    contentHandler: ContentHandlerCallback,
    udata: ref,
    connectionTimeout = defaultConnectionTimeout,
    readTimeout = defaultReadTimeout,
    rng = newRng()): T =
  GC_ref(udata)
  let
    stream = PortalStream(
      contentHandler: contentHandler,
      udata: cast[pointer](udata),
      connectionTimeout: connectionTimeout,
      readTimeout: readTimeout,
      rng: rng)

  stream

func setTransport*(stream: PortalStream, transport: UtpDiscv5Protocol) =
  stream.transport = transport

proc pruneAllowedConnections(stream: PortalStream) =
  # Prune requests and offers that didn't receive a connection request
  # before `connectionTimeout`.
  let now = Moment.now()
  stream.contentRequests.keepIf(proc(x: ContentRequest): bool =
    x.timeout > now)
  stream.contentOffers.keepIf(proc(x: ContentOffer): bool =
    x.timeout > now)

# TODO: I think I'd like it more if we weren't to capture the stream.
proc registerIncomingSocketCallback*(
    streams: seq[PortalStream]): AcceptConnectionCallback[NodeAddress] =
  return (
    proc(server: UtpRouter[NodeAddress], client: UtpSocket[NodeAddress]): Future[void] =
      for stream in streams:
        # Note: Connection id of uTP SYN is different from other packets, it is
        # actually the peers `send_conn_id`, opposed to `receive_conn_id` for all
        # other packets.
        for i, request in stream.contentRequests:
          if request.connectionId == client.connectionId and
              request.nodeId == client.remoteAddress.nodeId:
            let fut = client.writeAndClose(stream, request)
            stream.contentRequests.del(i)
            return fut

        for i, offer in stream.contentOffers:
          if offer.connectionId == client.connectionId and
              offer.nodeId == client.remoteAddress.nodeId:
            let fut = client.readAndClose(stream, offer)
            stream.contentOffers.del(i)
            return fut

      # TODO: Is there a scenario where this can happen,
      # considering `allowRegisteredIdCallback`? If not, doAssert?
      var fut = newFuture[void]("fluffy.AcceptConnectionCallback")
      fut.complete()
      return fut
  )

proc allowedConnection(
    stream: PortalStream, address: NodeAddress, connectionId: uint16): bool =
  return
    stream.contentRequests.any(
      proc (x: ContentRequest): bool =
        x.connectionId == connectionId and x.nodeId == address.nodeId) or
    stream.contentOffers.any(
      proc (x: ContentOffer): bool =
        x.connectionId == connectionId and x.nodeId == address.nodeId)

proc allowRegisteredIdCallback*(
    streams: seq[PortalStream]): AllowConnectionCallback[NodeAddress] =
  return (
    proc(r: UtpRouter[NodeAddress], remoteAddress: NodeAddress, connectionId: uint16): bool =
      for stream in streams:
        # stream.pruneAllowedConnections()
        if allowedConnection(stream, remoteAddress, connectionId):
          return true
  )
