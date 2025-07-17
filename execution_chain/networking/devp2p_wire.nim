# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/strutils,
  eth/rlp,
  chronos,
  ./protocol_registry,
  ./p2p_types,
  ./protocol_dsl

const
  devp2pSnappyVersion* = 5
    ## EIP-706 version of devp2p, with snappy compression - no support offered
    ## for earlier versions

  msgIdHello* = byte 0
  msgIdDisconnect* = byte 1
  msgIdPing* = byte 2
  msgIdPong* = byte 3

type
  DisconnectionReasonList* = object
    value*: DisconnectionReason

  HelloPacket* = object
    version*: uint64
    clientId*: string
    capabilities*: seq[Capability]
    listenPort*: uint
    nodeId*: array[RawPublicKeySize, byte]

  SendDisconnectPacket = object
    reason: DisconnectionReasonList

  # We need these two types in rlpx/devp2p as no parameters or single parameters
  # are not getting encoded in an rlp list.
  # TODO: we could generalize this in the protocol dsl but it would need an
  # `alwaysList` flag as not every protocol expects lists in these cases.
  EmptyList = object

  PingPacket = object
    list: EmptyList

  PongPacket = object
    list: EmptyList

#------------------------------------------------------------------------------
# DevP2P private helpers
#------------------------------------------------------------------------------

proc read*(
    rlp: var Rlp, T: type DisconnectionReasonList
): T {.gcsafe, raises: [RlpError].} =
  ## Rlp mixin: `DisconnectionReasonList` parser

  if rlp.isList:
    # Be strict here: The expression `rlp.read(DisconnectionReasonList)`
    # accepts lists with at least one item. The array expression wants
    # exactly one item.
    if rlp.rawData.len < 3:
      # avoids looping through all items when parsing for an overlarge array
      return DisconnectionReasonList(value: rlp.read(array[1, DisconnectionReason])[0])

  # Also accepted: a single byte reason code. Is is typically used
  # by variants of the reference implementation `Geth`
  elif rlp.blobLen <= 1:
    return DisconnectionReasonList(value: rlp.read(DisconnectionReason))

  # Also accepted: a blob of a list (aka object) of reason code. It is
  # used by `bor`, a `geth` fork
  elif rlp.blobLen < 4:
    var subList = rlp.toBytes.rlpFromBytes
    if subList.isList:
      # Ditto, see above.
      return
        DisconnectionReasonList(value: subList.read(array[1, DisconnectionReason])[0])

  raise newException(RlpTypeMismatch, "Single entry list expected")

#------------------------------------------------------------------------------
# DevP2P public functions
#------------------------------------------------------------------------------

defineProtocol(PROTO = DevP2P,
               version = devp2pSnappyVersion,
               rlpxName = "p2p",
               subProtocol = false)

proc hello*(peer: Peer;
           packet: HelloPacket;):
            Future[void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  DevP2P.rlpxSendMessage(peer, msgIdHello,
                    packet.version,
                    packet.clientId,
                    packet.capabilities,
                    packet.listenPort,
                    packet.nodeId)

proc sendDisconnectMsg*(peer: Peer;
                       reason: DisconnectionReasonList):
                         Future[void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  DevP2P.rlpxSendDisconnect(peer, msgIdDisconnect, reason)

proc ping*(peer: Peer): Future[void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  # Adding an empty RLP list as the spec defines.
  # The parity client specifically checks if there is rlp data.
  const emptyList = EmptyList()
  DevP2P.rlpxSendMessage(peer, msgIdPing, emptyList)

proc pong*(peer: Peer): Future[void] {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  const emptyList = EmptyList()
  DevP2P.rlpxSendMessage(peer, msgIdPong, emptyList)

#------------------------------------------------------------------------------
# DevP2P responder functions
#------------------------------------------------------------------------------
proc helloThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  DevP2P.rlpxWithPacketHandler(HelloPacket, peer, data,
                               [version, clientId,
                                capabilities, listenPort,
                                nodeId]):
    # The first hello message gets processed during the initial handshake - this
    # version is used for any subsequent messages

    # TODO investigate and turn warning into protocol breach
    warn "TODO Multiple hello messages received", remote = peer.remote,
      clientId = packet.clientId
    # await peer.disconnectAndRaise(BreachOfProtocol, "Multiple hello messages")

proc sendDisconnectMsgThunk(peer: Peer; data: Rlp) {.
    async: (raises: [CancelledError, EthP2PError]).} =
  DevP2P.rlpxWithPacketHandler(SendDisconnectPacket, peer, data, [reason]):
    ## Notify other peer that we're about to disconnect them for the given
    ## reason
    if packet.reason.value == BreachOfProtocol:
      # TODO This is a temporary log message at warning level to aid in
      #      debugging in pre-release versions - it should be removed before
      #      release
      # TODO Nethermind sends BreachOfProtocol on network id mismatch:
      #      https://github.com/NethermindEth/nethermind/issues/7727
      if not peer.clientId.startsWith("Nethermind"):
        warn "TODO Peer sent BreachOfProtocol error!",
          remote = peer.remote, clientId = peer.clientId
    else:
      trace "disconnect message received", reason = packet.reason.value, peer = peer.remote
    await peer.disconnectPeer(peer, packet.reason.value, false)

proc pingThunk(peer: Peer; data: Rlp) {.async: (raises: [CancelledError, EthP2PError]).} =
  DevP2P.rlpxWithPacketHandler(PingPacket, peer, data, [list]):
    discard peer.pong()

proc pongThunk(peer: Peer; data: Rlp) {.async: (raises: [CancelledError, EthP2PError]).} =
  DevP2P.rlpxWithPacketHandler(PongPacket, peer, data, [list]):
    discard

proc DevP2PRegistration() =
  let
    protocol = DevP2P.initProtocol()

  registerMsg(protocol, msgIdHello, "hello", helloThunk, HelloPacket)
  registerMsg(protocol, msgIdDisconnect, "sendDisconnectMsg",
              sendDisconnectMsgThunk, SendDisconnectPacket)
  registerMsg(protocol, msgIdPing, "ping",
              pingThunk, PingPacket)
  registerMsg(protocol, msgIdPong, "pong",
              pongThunk, PongPacket)
  registerProtocol(protocol)

DevP2PRegistration()
