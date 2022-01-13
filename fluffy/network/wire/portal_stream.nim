# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  chronos, stew/byteutils, chronicles,
  eth/utp/utp_discv5_protocol,
  # even though utp_discv5_protocol exports this, import is still needed,
  # perhaps protocol.Protocol type of usage?
  eth/p2p/discoveryv5/protocol,
  ./messages

export tables, utp_discv5_protocol

const utpProtocolId = "utp".toBytes()

type
  PortalStream* = ref object
    transport*: UtpDiscv5Protocol
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
    contentRequests*: Table[uint16, ByteList]
    contentOffers*: Table[uint16, ContentKeysList]

proc writeAndClose(socket: UtpSocket[Node], data: seq[byte]) {.async.} =
  let dataWritten =  await socket.write(data)
  if dataWritten.isErr():
    debug "Error writing requested data", error = dataWritten.error

  await socket.closeWait()

proc readAndClose(socket: UtpSocket[Node]) {.async.} =
  # Read all bytes from the socket
  # This will either end with a FIN, or because the read action times out.
  # A FIN does not necessarily mean that the data read is complete. Further
  # validation is required, using a length prefix here might be beneficial for
  # this.
  var readData = socket.read()
  if await readData.withTimeout(1.seconds):
    # TODO: Content needs to be validated, stored and also offered again as part
    # of the neighborhood gossip. This will require access to the specific
    # Portal wire protocol for the network it was received on. Some async event
    # will probably be required for this.
    let content = readData.read
    echo content.toHex()
  else:
    debug "Reading data from socket timed out, content request failed"

  await socket.closeWait()

# TODO: I think I'd like it more if we weren't to capture the stream.
proc registerIncomingSocketCallback(
    stream: PortalStream): AcceptConnectionCallback[Node] =
  return (
    proc(server: UtpRouter[Node], client: UtpSocket[Node]): Future[void] =
      # Note: Connection id of uTP SYN is different from other packets, it is
      # actually the peers `send_conn_id`, opposed to `receive_conn_id` for all
      # other packets.
      var content: ByteList
      if stream.contentRequests.pop(client.connectionId, content):
        let fut = client.writeAndClose(content.asSeq())
        return fut

      var contentKeys: ContentKeysList
      if stream.contentOffers.pop(client.connectionId, contentKeys):
        let fut = client.readAndClose()
        return fut

      # TODO: Is there a scenario where this can happen,
      # considering `allowRegisteredIdCallback`? If not, doAssert?
      var fut = newFuture[void]("fluffy.AcceptConnectionCallback")
      fut.complete()
      return fut
  )

proc allowRegisteredIdCallback(
    stream: PortalStream): AllowConnectionCallback[Node] =
  return (
    proc(r: UtpRouter[Node], remoteAddress: Node, connectionId: uint16): bool =
      # This is the connection id of the uTP SYN packet header, thus the peers
      # `send_conn_id`.
      stream.contentRequests.contains(connectionId) or
        stream.contentOffers.contains(connectionId)
  )

proc new*(T: type PortalStream): T =
  # Tables are initialized by default, and the transport is initialized in open
  PortalStream()

proc open*(s: PortalStream, baseProtocol: protocol.Protocol) =
  let socketConfig = SocketConfig.init(
    incomingSocketReceiveTimeout = none(Duration))
  s.transport = UtpDiscv5Protocol.new(
    baseProtocol,
    utpProtocolId,
    registerIncomingSocketCallback(s),
    allowRegisteredIdCallback(s),
    socketConfig)
