# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements the `RLPx` Transport Protocol defined at
## `RLPx <https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md>`_
## in its EIP-8 version.
##
## This modules implements version 5 of the p2p protocol as defined by EIP-706 -
## earlier versions are not supported.
##
## Both, the message ID and the request/response ID are now unsigned. This goes
## along with the RLPx specs (see above) and the sub-protocol specs at
## `sub-proto <https://github.com/ethereum/devp2p/tree/master/caps>`_ plus the
## fact that RLP is defined for non-negative integers smaller than 2^64 only at
## `Yellow Paper <https://ethereum.github.io/yellowpaper/paper.pdf#appendix.B>`_,
## Appx B, clauses (195) ff and (199).
##

{.push raises: [].}

import
  std/[deques, os, sequtils, strutils, typetraits, tables],
  stew/byteutils,
  chronicles,
  chronos,
  eth/rlp,
  eth/enode/enode,
  snappy,
  ./protocol_dsl,
  ./peer_pool,
  ./devp2p_wire,
  ./p2p_metrics,
  ./rlpx/[auth, rlpxcrypt],
  ./discoveryv4/kademlia

const
  maxMsgSize = 1024 * 1024 * 16
    ## The maximum message size is normally limited by the 24-bit length field in
    ## the message header but in the case of snappy, we need to protect against
    ## decompression bombs:
    ## https://eips.ethereum.org/EIPS/eip-706#avoiding-dos-attacks

  connectionTimeout = 10.seconds

# TODO: chronicles re-export here is added for the error
# "undeclared identifier: 'activeChroniclesStream'", when the code using p2p
# does not import chronicles. Need to resolve this properly.
export options, rlp, chronicles, protocol_dsl

logScope:
  topics = "p2p rlpx"

include p2p_tracing

when tracingEnabled:
  import eth/common/eth_types_json_serialization

  export
    # XXX: This is a work-around for a Nim issue.
    # See a more detailed comment in p2p_tracing.nim
    init,
    writeValue,
    getOutput

chronicles.formatIt(Peer):
  $(it.remote)
chronicles.formatIt(Opt[uint64]):
  (if it.isSome(): $it.value else: "-1")

proc disconnect*(
    peer: Peer, reason: DisconnectionReason, notifyRemote = false
) {.async: (raises: []).}

# Dispatcher
#

proc getDispatcher(
    node: EthereumNode, otherPeerCapabilities: openArray[Capability]
): Opt[Dispatcher] =
  template copyTo(src, dest; index: int) =
    for i in 0 ..< src.len:
      dest[index + i] = src[i]

  func addOrReplace(dispatcher: Dispatcher, localProtocol: ProtocolInfo) =
    for i, proto in dispatcher.activeProtocols:
      if proto.capability.name == localProtocol.capability.name:
        if localProtocol.capability.version > proto.capability.version:
          dispatcher.activeProtocols[i] = localProtocol
        return

    dispatcher.activeProtocols.add localProtocol
    localProtocol.messages.copyTo(
      dispatcher.messages, dispatcher.protocolOffsets[localProtocol.index].value.int
    )

  let dispatcher = Dispatcher()
  var nextUserMsgId = 0x10u64

  for localProtocol in node.protocols:
    let idx = localProtocol.index
    block findMatchingProtocol:
      for remoteCapability in otherPeerCapabilities:
        if localProtocol.capability == remoteCapability:
          dispatcher.protocolOffsets[idx] = Opt.some(nextUserMsgId)
          nextUserMsgId += localProtocol.messages.len.uint64
          break findMatchingProtocol

  dispatcher.messages = newSeq[MessageInfo](nextUserMsgId)
  devp2pInfo.messages.copyTo(dispatcher.messages, 0)

  for localProtocol in node.protocols:
    let idx = localProtocol.index
    if dispatcher.protocolOffsets[idx].isSome:
      dispatcher.addOrReplace(localProtocol)

  if dispatcher.numProtocols == 0:
    Opt.none(Dispatcher)
  else:
    Opt.some(dispatcher)


proc handshakeImpl*[T](
    peer: Peer,
    sendFut: Future[void],
    responseFut: auto, # Future[T].Raising([CancelledError, EthP2PError]),
    timeout: Duration,
): Future[T] {.async: (raises: [CancelledError, EthP2PError]).} =
  sendFut.addCallback do(arg: pointer) {.gcsafe.}:
    if sendFut.failed:
      debug "Handshake message not delivered", peer

  doAssert timeout.milliseconds > 0

  try:
    let res = await responseFut.wait(timeout)
    return res
  except AsyncTimeoutError:
    # TODO: Really shouldn't disconnect and raise everywhere. In order to avoid
    # understanding what error occured where.
    # And also, incoming and outgoing disconnect errors should be seperated,
    # probably by seperating the actual disconnect call to begin with.
    await disconnectAndRaise(peer, TcpError, T.name() & " was not received in time.")

proc getMsgName*(peer: Peer, msgId: uint64): string =
  if not peer.dispatcher.isNil and msgId < peer.dispatcher.messages.len.uint64 and
      not peer.dispatcher.messages[msgId].isNil:
    return peer.dispatcher.messages[msgId].name
  else:
    return
      case msgId
      of msgIdHello:
        "hello"
      of msgIdDisconnect:
        "disconnect"
      of msgIdPing:
        "ping"
      of msgIdPong:
        "pong"
      else:
        $msgId

proc cmp*(lhs, rhs: ProtocolInfo): int =
  let c = cmp(lhs.capability.name, rhs.capability.name)
  if c == 0:
    # Highest version first!
    -cmp(lhs.capability.version, rhs.capability.version)
  else:
    c

proc invokeThunk*(
    peer: Peer, msgId: uint64, msgData: Rlp
): Future[void] {.async: (raises: [CancelledError, EthP2PError]).} =
  template invalidIdError(): untyped =
    raise newException(
      UnsupportedMessageError,
      "RLPx message with an invalid id " & $msgId & " on a connection supporting " &
        peer.dispatcher.describeProtocols,
    )

  if msgId >= peer.dispatcher.messages.len.uint64 or
      peer.dispatcher.messages[msgId].isNil:
    invalidIdError()
  let msgInfo = peer.dispatcher.messages[msgId]

  doAssert peer.dispatcher.messages.len == peer.perMsgId.len,
    "Should have been set up in peer constructor"

  # Check if the peer is "expecting" this message as part of a handshake
  if peer.perMsgId[msgId].awaitedMessage != nil:
    let awaited = move(peer.perMsgId[msgId].awaitedMessage)
    peer.perMsgId[msgId].awaitedMessage = nil

    try:
      msgInfo.nextMsgResolver(msgData, awaited)
    except rlp.RlpError as exc:
      await peer.disconnectAndRaise(
        BreachOfProtocol, "Could not decode rlp id: " & $msgId &
        ", name: " & msgInfo.name & ", msg: " & exc.msg
      )
  else:
    await msgInfo.thunk(peer, msgData)

proc recvMsg(
    peer: Peer
): Future[tuple[msgId: uint64, msgRlp: Rlp]] {.
    async: (raises: [CancelledError, EthP2PError])
.} =
  var msgBody: seq[byte]
  try:
    msgBody = await peer.transport.recvMsg()

    trace "Received message",
      remote = peer.remote,
      clientId = peer.clientId,
      data = toHex(msgBody.toOpenArray(0, min(255, msgBody.high)))

    # TODO we _really_ need an rlp decoder that doesn't require this many
    #      copies of each message...
    var tmp = rlpFromBytes(msgBody)
    let msgId = tmp.read(uint64)

    if peer.snappyEnabled and tmp.hasData():
      let decoded =
        snappy.decode(msgBody.toOpenArray(tmp.position, msgBody.high), maxMsgSize)
      if decoded.len == 0:
        if msgId == 0x01 and msgBody.len > 1 and msgBody.len < 16 and msgBody[1] == 0xc1:
          # Nethermind sends its TooManyPeers uncompressed but we want to be nice!
          # https://github.com/NethermindEth/nethermind/issues/7726
          debug "Trying to decode disconnect uncompressed",
            remote = peer.remote, clientId = peer.clientId, data = toHex(msgBody)
        else:
          await peer.disconnectAndRaise(
            BreachOfProtocol, "Could not decompress snappy data"
          )
      else:
        trace "Decoded message",
          remote = peer.remote,
          clientId = peer.clientId,
          decoded = toHex(decoded.toOpenArray(0, min(255, decoded.high)))
        tmp = rlpFromBytes(decoded)

    return (msgId, tmp)
  except TransportError as exc:
    await peer.disconnectAndRaise(TcpError, exc.msg)
  except RlpxTransportError as exc:
    await peer.disconnectAndRaise(BreachOfProtocol, exc.msg)
  except RlpError as exc:
    # TODO remove this warning before using in production
    warn "TODO: RLP decoding failed for msgId",
      remote = peer.remote,
      clientId = peer.clientId,
      err = exc.msg,
      rawData = toHex(msgBody)

    await peer.disconnectAndRaise(BreachOfProtocol, "Could not decode msgId")

proc dispatchMessages(peer: Peer) {.async: (raises: []).} =
  try:
    while peer.connectionState notin {Disconnecting, Disconnected}:
      var (msgId, msgData) = await peer.recvMsg()

      await peer.invokeThunk(msgId, msgData)
  except EthP2PError:
    # TODO Is this needed? Most such exceptions are raised with an accompanying
    #      disconnect already .. ClientQuitting isn't a great error but as good
    #      as any since it will have no effect if the disconnect already happened
    await peer.disconnect(ClientQuitting)
  except CancelledError:
    await peer.disconnect(ClientQuitting)

#------------------------------------------------------------------------------
# Rlpx Implementation
#------------------------------------------------------------------------------

proc removePeer(network: EthereumNode, peer: Peer) =
  # It is necessary to check if peer.remote still exists. The connection might
  # have been dropped already from the peers side.
  # E.g. when receiving a p2p.disconnect message from a peer, a race will happen
  # between which side disconnects first.
  if network.peerPool != nil and not peer.remote.isNil and
      peer.remote in network.peerPool.connectedNodes:
    network.peerPool.connectedNodes.del(peer.remote)
    rlpx_connected_peers.dec()

    # Note: we need to do this check as disconnect (and thus removePeer)
    # currently can get called before the dispatcher is initialized.
    if not peer.dispatcher.isNil:
      for observer in network.peerPool.observers.values:
        if not observer.onPeerDisconnected.isNil:
          if observer.protocols.len == 0 or peer.supports(observer.protocols):
            observer.onPeerDisconnected(peer)

proc disconnect*(
    peer: Peer, reason: DisconnectionReason, notifyRemote = false
) {.async: (raises: []).} =
  if reason == BreachOfProtocol:
    # TODO remove warning after all protocol breaches have been investigated
    # TODO https://github.com/NethermindEth/nethermind/issues/7727
    if not peer.clientId.startsWith("Nethermind"):
      warn "TODO disconnecting peer because of protocol breach",
        remote = peer.remote, clientId = peer.clientId
  if peer.connectionState notin {Disconnecting, Disconnected}:
    if peer.connectionState == Connected:
      # Only log peers that successfully completed the full connection setup -
      # the others should have been logged already
      debug "Peer disconnected", remote = peer.remote, clientId = peer.clientId, reason

    peer.connectionState = Disconnecting

    # Do this first so sub-protocols have time to clean up and stop sending
    # before this node closes transport to remote peer
    if not peer.dispatcher.isNil:
      # Notify all pending handshake handlers that a disconnection happened
      for msgId, x in peer.perMsgId.mpairs:
        if x.awaitedMessage.isNil.not:
          var tmp = x.awaitedMessage
          x.awaitedMessage = nil
          peer.dispatcher.messages[msgId].failResolver(reason, tmp)

        while x.outstandingRequest.len > 0:
          let req = x.outstandingRequest.popFirst()
          # Same as when they timeout
          peer.dispatcher.messages[msgId].requestResolver(nil, req.future)

      # In case of `CatchableError` in any of the handlers, this will be logged.
      # Other handlers will still execute.
      # In case of `Defect` in any of the handlers, program will quit.
      await callDisconnectHandlers(peer, reason)

    if notifyRemote and not peer.transport.closed:
      proc waitAndClose(
          transport: RlpxTransport, time: Duration
      ) {.async: (raises: []).} =
        await noCancel sleepAsync(time)
        await noCancel peer.transport.closeWait()

      try:
        await peer.sendDisconnectMsg(DisconnectionReasonList(value: reason))
      except CatchableError as e:
        trace "Failed to deliver disconnect message",
          peer, err = e.msg, errName = e.name

      # Give the peer a chance to disconnect
      asyncSpawn peer.transport.waitAndClose(2.seconds)
    elif not peer.transport.closed:
      peer.transport.close()

    logDisconnectedPeer peer
    peer.connectionState = Disconnected
    removePeer(peer.network, peer)

proc initPeerState(
    peer: Peer, h: HelloPacket
) {.raises: [UselessPeerError].} =
  peer.clientId = h.clientId
  peer.dispatcher = getDispatcher(peer.network, h.capabilities).valueOr:
    raise (ref UselessPeerError)(
      msg: "No capabilities in common: " & h.capabilities.mapIt($it).join(",")
    )

  # The dispatcher has determined our message ID sequence.
  # For each message ID, we allocate a potential slot for
  # tracking responses to requests.
  # (yes, some of the slots won't be used).
  #
  # Similarly, we need a bit of book-keeping data to keep track
  # of the potentially concurrent calls to `nextMsg`.
  peer.perMsgId.newSeq(peer.dispatcher.messages.len)
  for d in mitems(peer.perMsgId):
    d.outstandingRequest = initDeque[OutstandingRequest]()

  peer.lastReqId = Opt.some(0u64)
  peer.initPeerStates peer.dispatcher.activeProtocols

proc postHelloSteps(
    peer: Peer, h: HelloPacket
) {.async: (raises: [CancelledError, EthP2PError]).} =

  initPeerState(peer, h)

  # Please note that the ordering of operations here is important!
  #
  # We must first start all handshake procedures and give them a
  # chance to send any initial packages they might require over
  # the network and to yield on their `nextMsg` waits.
  #

  let handshakes = peer.dispatcher.activeProtocols
    .filterIt(it.onPeerConnected != nil)
    .mapIt(it.onPeerConnected(peer))

  # The `dispatchMessages` loop must be started after this.
  # Otherwise, we risk that some of the handshake packets sent by
  # the other peer may arrive too early and be processed before
  # the handshake code got a change to wait for them.
  #
  let messageProcessingLoop = peer.dispatchMessages()

  # The handshake may involve multiple async steps, so we wait
  # here for all of them to finish.
  #
  await allFutures(handshakes)

  for handshake in handshakes:
    if not handshake.completed():
      await handshake # raises correct error without actually waiting

  # This is needed as a peer might have already disconnected. In this case
  # we need to raise so that rlpxConnect/rlpxAccept fails.
  # Disconnect is done only to run the disconnect handlers. TODO: improve this
  # also TODO: Should we discern the type of error?
  if messageProcessingLoop.finished:
    await peer.disconnectAndRaise(
      ClientQuitting, "messageProcessingLoop ended while connecting"
    )
  peer.connectionState = Connected

template setSnappySupport(peer: Peer, hello: HelloPacket) =
  peer.snappyEnabled = hello.version >= devp2pSnappyVersion.uint64

type RlpxError* = enum
  TransportConnectError
  RlpxHandshakeTransportError
  RlpxHandshakeError
  ProtocolError
  P2PHandshakeError
  P2PTransportError
  InvalidIdentityError
  UselessRlpxPeerError
  PeerDisconnectedError
  TooManyPeersError

proc helloHandshake(
    node: EthereumNode, peer: Peer
): Future[HelloPacket] {.async: (raises: [CancelledError, EthP2PError]).} =
  ## Negotiate common capabilities using the p2p `hello` message

  # https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md#hello-0x00

  await peer.hello(
    HelloPacket(
      version: devp2pSnappyVersion,
      clientId: node.clientId,
      capabilities: node.capabilities,
      listenPort: 0, # obsolete
      nodeId: node.keys.pubkey.toRaw(),
    )
  )

  # The first message received must be a hello or a disconnect
  var (msgId, msgData) = await peer.recvMsg()

  try:
    case msgId
    of msgIdHello:
      # Implementations must ignore any additional list elements in Hello
      # because they may be used by a future version.
      let response = msgData.read(HelloPacket)
      trace "Received Hello", version = response.version, id = response.clientId

      if response.nodeId != peer.transport.pubkey.toRaw:
        await peer.disconnectAndRaise(
          BreachOfProtocol, "nodeId in hello does not match RLPx transport identity"
        )

      return response
    of msgIdDisconnect: # Disconnection requested by peer
      # TODO distinguish their reason from ours
      let reason = msgData.read(DisconnectionReasonList).value
      await peer.disconnectAndRaise(
        reason, "Peer disconnecting during hello: " & $reason
      )
    else:
      # No other messages may be sent until a Hello is received.
      await peer.disconnectAndRaise(BreachOfProtocol, "Expected hello, got " & $msgId)
  except RlpError:
    await peer.disconnectAndRaise(BreachOfProtocol, "Could not decode hello RLP")

proc rlpxConnect*(
    node: EthereumNode, remote: Node
): Future[Result[Peer, RlpxError]] {.async: (raises: [CancelledError]).} =
  # TODO move logging elsewhere - the aim is to have exactly _one_ debug log per
  #      connection attempt (success or failure) to not spam the logs
  initTracing(devp2pInfo, node.protocols)
  logScope:
    remote
  trace "Connecting to peer"

  let
    peer = Peer(remote: remote, network: node, disconnectPeer: disconnect, inbound: false)
    deadline = sleepAsync(connectionTimeout)

  var error = true

  defer:
    deadline.cancelSoon() # Harmless if finished

    if error: # TODO: Not sure if I like this much
      if peer.transport != nil:
        peer.transport.close()

  peer.transport =
    try:
      let ta = initTAddress(remote.node.address.ip, remote.node.address.tcpPort)
      await RlpxTransport.connect(node.rng, node.keys, ta, remote.node.pubkey).wait(
        deadline
      )
    except AsyncTimeoutError:
      debug "Connect timeout"
      return err(TransportConnectError)
    except RlpxTransportError as exc:
      debug "Connect RlpxTransport error", err = exc.msg
      return err(ProtocolError)
    except TransportError as exc:
      debug "Connect transport error", err = exc.msg
      return err(TransportConnectError)

  logConnectedPeer peer

  # RLPx p2p capability handshake: After the initial handshake, both sides of
  # the connection must send either Hello or a Disconnect message.
  let response =
    try:
      await node.helloHandshake(peer).wait(deadline)
    except AsyncTimeoutError:
      debug "Connect handshake timeout"
      return err(P2PHandshakeError)
    except PeerDisconnected as exc:
      debug "Connect handshake disconnection", err = exc.msg, reason = exc.reason
      case exc.reason
      of TooManyPeers:
        return err(TooManyPeersError)
      else:
        return err(PeerDisconnectedError)
    except UselessPeerError as exc:
      debug "Useless peer during handshake", err = exc.msg
      return err(UselessRlpxPeerError)
    except EthP2PError as exc:
      debug "Connect handshake error", err = exc.msg
      return err(PeerDisconnectedError)

  if response.version < devp2pSnappyVersion:
    await peer.disconnect(IncompatibleProtocolVersion, notifyRemote = true)
    debug "Peer using obsolete devp2p version",
      version = response.version, clientId = response.clientId
    return err(UselessRlpxPeerError)

  peer.setSnappySupport(response)

  logScope:
    clientId = response.clientId

  trace "DevP2P handshake completed"

  try:
    await postHelloSteps(peer, response)
  except PeerDisconnected as exc:
    debug "Disconnect finishing hello",
      remote, clientId = response.clientId, err = exc.msg, reason = exc.reason
    case exc.reason
    of TooManyPeers:
      return err(TooManyPeersError)
    else:
      return err(PeerDisconnectedError)
  except UselessPeerError as exc:
    debug "Useless peer finishing hello", err = exc.msg
    return err(UselessRlpxPeerError)
  except EthP2PError as exc:
    debug "P2P error finishing hello", err = exc.msg
    return err(ProtocolError)

  debug "Peer connected", capabilities = response.capabilities, peer=peer.clientId

  error = false

  return ok(peer)

# TODO: rework rlpxAccept similar to rlpxConnect.
proc rlpxAccept*(
    node: EthereumNode, stream: StreamTransport
): Future[Peer] {.async: (raises: [CancelledError, EthP2PError]).} =
  # TODO move logging elsewhere - the aim is to have exactly _one_ debug log per
  #      connection attempt (success or failure) to not spam the logs
  initTracing(devp2pInfo, node.protocols)

  let
    peer = Peer(network: node, disconnectPeer: disconnect, inbound: true)
    deadline = sleepAsync(connectionTimeout)

  var error = true
  defer:
    deadline.cancelSoon()

    if error:
      stream.close()

  let remoteAddress =
    try:
      stream.remoteAddress()
    except TransportError as exc:
      debug "Could not get remote address", err = exc.msg
      return nil

  trace "Incoming connection", remoteAddress = $remoteAddress

  peer.transport =
    try:
      await RlpxTransport.accept(node.rng, node.keys, stream).wait(deadline)
    except AsyncTimeoutError:
      debug "Accept timeout", remoteAddress = $remoteAddress
      rlpx_accept_failure.inc(labelValues = ["timeout"])
      return nil
    except RlpxTransportError as exc:
      debug "Accept RlpxTransport error", remoteAddress = $remoteAddress, err = exc.msg
      rlpx_accept_failure.inc(labelValues = [$BreachOfProtocol])
      return nil
    except TransportError as exc:
      debug "Accept transport error", remoteAddress = $remoteAddress, err = exc.msg
      rlpx_accept_failure.inc(labelValues = [$TcpError])
      return nil

  let
    # The ports in this address are not necessarily the ports that the peer is
    # actually listening on, so we cannot use this information to connect to
    # the peer in the future!
    ip =
      try:
        remoteAddress.address
      except ValueError:
        raiseAssert "only tcp sockets supported"
    address = Address(ip: ip, tcpPort: remoteAddress.port, udpPort: remoteAddress.port)

  peer.remote = newNode(ENode(pubkey: peer.transport.pubkey, address: address))

  logAcceptedPeer peer

  logScope:
    remote = peer.remote

  let response =
    try:
      await node.helloHandshake(peer).wait(deadline)
    except AsyncTimeoutError:
      debug "Accept handshake timeout"
      rlpx_accept_failure.inc(labelValues = ["timeout"])
      return nil
    except PeerDisconnected as exc:
      debug "Accept handshake disconnection", err = exc.msg, reason = exc.reason
      rlpx_accept_failure.inc(labelValues = [$exc.reason])
      return nil
    except EthP2PError as exc:
      debug "Accept handshake error", err = exc.msg
      rlpx_accept_failure.inc(labelValues = ["error"])
      return nil

  if response.version < devp2pSnappyVersion:
    await peer.disconnect(IncompatibleProtocolVersion, notifyRemote = true)
    debug "Peer using obsolete devp2p version",
      version = response.version, clientId = response.clientId
    rlpx_accept_failure.inc(labelValues = [$IncompatibleProtocolVersion])
    return nil

  peer.setSnappySupport(response)

  logScope:
    clientId = response.clientId

  trace "DevP2P handshake completed", response

  # In case there is an outgoing connection started with this peer we give
  # precedence to that one and we disconnect here with `AlreadyConnected`
  if peer.remote in node.peerPool.connectedNodes or
      peer.remote in node.peerPool.connectingNodes:
    trace "Duplicate connection in rlpxAccept"
    rlpx_accept_failure.inc(labelValues = [$AlreadyConnected])
    return nil

  node.peerPool.connectingNodes.incl(peer.remote)

  try:
    await postHelloSteps(peer, response)
  except PeerDisconnected as exc:
    debug "Disconnect while accepting", reason = exc.reason, err = exc.msg
    rlpx_accept_failure.inc(labelValues = [$exc.reason])
    return nil
  except UselessPeerError as exc:
    debug "Useless peer while accepting", err = exc.msg

    rlpx_accept_failure.inc(labelValues = [$UselessPeer])
    return nil
  except EthP2PError as exc:
    trace "P2P error during accept", err = exc.msg
    rlpx_accept_failure.inc(labelValues = [$exc.name])
    return nil

  debug "Peer accepted", capabilities = response.capabilities, peer=peer.clientId

  error = false
  rlpx_accept_success.inc()

  return peer
