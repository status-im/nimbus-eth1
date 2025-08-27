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
  std/sequtils,
  chronos,
  chronicles/formats as chronicles,
  results,
  ./p2p_enums,
  ./p2p_protocols,
  ./rlpx/rlpxtransport

from ./discoveryv4/kademlia import Node, NodeId

export
  p2p_protocols, rlpxtransport

type
  ## Peer usually instantiated by PeerRef
  ## Network usually instantiated by EthereumNode
  DispatcherRef*[Peer, Network] = ref object # private
    # The dispatcher stores the mapping of negotiated message IDs between
    # two connected peers. The dispatcher may be shared between connections
    # running with the same set of supported protocols.
    #
    # `protocolOffsets` will hold one slot of each locally supported
    # protocol. If the other peer also supports the protocol, the stored
    # offset indicates the numeric value of the first message of the protocol
    # (for this particular connection). If the other peer doesn't support the
    # particular protocol, the stored offset is `Opt.none(uint64)`.
    #
    # `messages` holds a mapping from valid message IDs to their handler procs.
    #
    protocolOffsets*: array[MAX_PROTOCOLS, Opt[uint64]]
    messages*: seq[MessageInfoRef[Peer]] # per `msgId` table (see above)
    activeProtocols*: seq[ProtocolInfoRef[Peer, Network]]

  OutstandingRequest* = object
    id*: uint64 # a `reqId` that may be used for response
    future*: FutureBase

  DisconnectPeer*[Peer] = proc(peer: Peer,
    reason: DisconnectionReason, notifyRemote = false) {.async: (raises: []).}

  PerMsgId* = object
    outstandingRequest*: Deque[OutstandingRequest]
    awaitedMessage*: FutureBase

  ## Network usually instantiated by EthereumNode
  PeerRef*[Network] = ref object
    remote*: Node
    network*: Network

    # Private fields:
    transport*: RlpxTransport
    dispatcher*: DispatcherRef[PeerRef[Network], Network]
    lastReqId*: Opt[uint64]
    connectionState*: ConnectionState
    peerStates*: array[MAX_PROTOCOLS, RootRef] # e.g. Eth69State or Eth68State
    perMsgId*: seq[PerMsgId]
    disconnectPeer*: DisconnectPeer[PeerRef[Network]]
    snappyEnabled*: bool
    clientId*: string
    inbound*: bool  # true if connection was initiated by remote peer

#------------------------------------------------------------------------------
# PeerRef public functions
#------------------------------------------------------------------------------

func id*(peer: PeerRef): NodeId =
  peer.remote.id

func `$`*(peer: PeerRef): string =
  $peer.remote

chronicles.formatIt(PeerRef):
  $it

func `$`*(x: DisconnectPeer): string =
  if x.isNil: "DisconnectPeer(nil)"
  else: "DisconnectPeer(cb)"

func perPeerMsgIdImpl*(peer: PeerRef, proto: ProtocolInfoRef, msgId: uint64): uint64 =
  result = msgId
  if not peer.dispatcher.isNil:
    result += peer.dispatcher.protocolOffsets[proto.index].value

func supports*(peer: PeerRef, proto: ProtocolInfoRef): bool =
  peer.dispatcher.protocolOffsets[proto.index].isSome

func supports*(peer: PeerRef, Protocol: type): bool =
  mixin protocolInfo
  ## Checks whether a Peer supports a particular protocol
  peer.supports(Protocol.protocolInfo)

func supports*(peer: PeerRef, protos: openArray[ProtocolInfoRef]): bool =
  for proto in protos:
    if peer.supports(proto):
      return true

func initPeerStates*(peer: PeerRef, protocols: openArray[ProtocolInfoRef]) =
  # Initialize all the active protocol states
  for protocol in protocols:
    let peerStateInit = protocol.peerStateInitializer
    if peerStateInit != nil:
      peer.peerStates[protocol.index] = peerStateInit(peer)

proc callDisconnectHandlers*(
    peer: PeerRef, reason: DisconnectionReason
): Future[void] {.async: (raises: []).} =
  let futures = peer.dispatcher.activeProtocols
    .filterIt(it.onPeerDisconnected != nil)
    .mapIt(it.onPeerDisconnected(peer, reason))

  await noCancel allFutures(futures)

#------------------------------------------------------------------------------
# DispatcherRef public functions
#------------------------------------------------------------------------------

func describeProtocols*(d: DispatcherRef): string =
  d.activeProtocols.mapIt($it.capability).join(",")

func numProtocols*(d: DispatcherRef): int =
  d.activeProtocols.len
