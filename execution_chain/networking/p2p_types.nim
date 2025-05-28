# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[deques, tables],
  chronos,
  results,
  eth/rlp,
  eth/common/[base, keys],
  ./discoveryv4,
  ./rlpx/rlpxtransport,
  ./discoveryv4/[enode, kademlia]

export base.NetworkId, rlpxtransport, kademlia

type
  EthereumNode* = ref object
    networkId*: NetworkId
    clientId*: string
    connectionState*: ConnectionState
    keys*: KeyPair
    address*: Address # The external address that the node will be advertising
    peerPool*: PeerPool
    bindIp*: IpAddress
    bindPort*: Port

    # Private fields:
    capabilities*: seq[Capability]
    protocols*: seq[ProtocolInfo]
    listeningServer*: StreamServer
    protocolStates*: seq[RootRef]
    discovery*: DiscoveryProtocol
    rng*: ref HmacDrbgContext

  Peer* = ref object
    remote*: Node
    network*: EthereumNode

    # Private fields:
    transport*: RlpxTransport
    dispatcher*: Dispatcher
    lastReqId*: Opt[uint64]
    connectionState*: ConnectionState
    protocolStates*: seq[RootRef]
    outstandingRequests*: seq[Deque[OutstandingRequest]] # per `msgId` table
    awaitedMessages*: seq[FutureBase] # per `msgId` table
    snappyEnabled*: bool
    clientId*: string

  SeenNode* = object
    nodeId*: NodeId
    stamp*: chronos.Moment

  PeerPool* = ref object
    # Private fields:
    network*: EthereumNode
    keyPair*: KeyPair
    networkId*: NetworkId
    minPeers*: int
    clientId*: string
    discovery*: DiscoveryProtocol
    lastLookupTime*: float
    connQueue*: AsyncQueue[Node]
    seenTable*: Table[NodeId, SeenNode]
    connectedNodes*: Table[Node, Peer]
    connectingNodes*: HashSet[Node]
    running*: bool
    observers*: Table[int, PeerObserver]

  PeerObserver* = object
    onPeerConnected*: proc(p: Peer) {.gcsafe, raises: [].}
    onPeerDisconnected*: proc(p: Peer) {.gcsafe, raises: [].}
    protocols*: seq[ProtocolInfo]

  Capability* = object
    name*: string
    version*: uint64

  EthP2PError* = object of CatchableError

  UnsupportedProtocol* = object of EthP2PError
    # This is raised when you attempt to send a message from a particular
    # protocol to a peer that doesn't support the protocol.

  MalformedMessageError* = object of EthP2PError
  UnsupportedMessageError* = object of EthP2PError

  PeerDisconnected* = object of EthP2PError
    reason*: DisconnectionReason

  UselessPeerError* = object of EthP2PError

  P2PInternalError* = object of EthP2PError

  ##
  ## Quasy-private types. Use at your own risk.
  ##
  ProtocolManager* = ref object
    protocols*: seq[ProtocolInfo]

  ProtocolInfo* = ref object
    capability*: Capability
    messages*: seq[MessageInfo]
    index*: int # the position of the protocol in the
                # ordered list of supported protocols

    # Private fields:
    peerStateInitializer*: PeerStateInitializer
    networkStateInitializer*: NetworkStateInitializer

    onPeerConnected*: OnPeerConnectedHandler
    onPeerDisconnected*: OnPeerDisconnectedHandler

  MessageInfo* = ref object
    id*: uint64 # this is a `msgId` (as opposed to a `reqId`)
    name*: string

    # Private fields:
    thunk*: ThunkProc
    printer*: MessageContentPrinter
    requestResolver*: RequestResolver
    nextMsgResolver*: NextMsgResolver
    failResolver*: FailResolver

  Dispatcher* = ref object # private
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
    protocolOffsets*: seq[Opt[uint64]]
    messages*: seq[MessageInfo] # per `msgId` table (se above)
    activeProtocols*: seq[ProtocolInfo]

  ##
  ## Private types:
  ##

  OutstandingRequest* = object
    id*: uint64 # a `reqId` that may be used for response
    future*: FutureBase

  # Private types:
  MessageHandlerDecorator* = proc(msgId: uint64, n: NimNode): NimNode

  ThunkProc* = proc(x: Peer, data: Rlp): Future[void]
    {.async: (raises: [CancelledError, EthP2PError]).}

  MessageContentPrinter* = proc(msg: pointer): string
    {.gcsafe, raises: [].}

  RequestResolver* = proc(msg: pointer, future: FutureBase)
    {.gcsafe, raises: [].}

  NextMsgResolver* = proc(msgData: Rlp, future: FutureBase)
    {.gcsafe, raises: [RlpError].}

  FailResolver* = proc(reason: DisconnectionReason, future: FutureBase)
    {.gcsafe, raises: [].}

  PeerStateInitializer* = proc(peer: Peer): RootRef
    {.gcsafe, raises: [].}

  NetworkStateInitializer* = proc(network: EthereumNode): RootRef
    {.gcsafe, raises: [].}

  OnPeerConnectedHandler* = proc(peer: Peer): Future[void]
    {.async: (raises: [CancelledError, EthP2PError]).}

  OnPeerDisconnectedHandler* = proc(peer: Peer, reason: DisconnectionReason):
    Future[void] {.async: (raises: []).}

  ConnectionState* = enum
    None,
    Connecting,
    Connected,
    Disconnecting,
    Disconnected

  # Disconnect message reasons as specified:
  # https://github.com/ethereum/devp2p/blob/master/rlpx.md#disconnect-0x01
  # Receiving values that are too large or that are in the enum hole will
  # trigger `RlpTypeMismatch` error on deserialization.
  DisconnectionReason* = enum
    DisconnectRequested = 0x00,
    TcpError = 0x01,
    BreachOfProtocol = 0x02,
    UselessPeer = 0x03,
    TooManyPeers = 0x04,
    AlreadyConnected = 0x05,
    IncompatibleProtocolVersion = 0x06,
    NullNodeIdentityReceived = 0x07,
    ClientQuitting = 0x08,
    UnexpectedIdentity = 0x09,
    SelfConnection = 0x0A,
    PingTimeout = 0x0B,
    SubprotocolReason = 0x10

  Address = enode.Address

proc `$`*(peer: Peer): string = $peer.remote

proc `$`*(v: Capability): string = v.name & "/" & $v.version

proc toENode*(v: EthereumNode): ENode =
  ENode(pubkey: v.keys.pubkey, address: v.address)

func id*(peer: Peer): NodeId =
  peer.remote.id
