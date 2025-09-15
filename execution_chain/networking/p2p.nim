# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/[tables, algorithm, typetraits, strutils, net],
  chronos, chronos/timer, chronicles,
  eth/common/keys,
  results,
  ./[peer_pool, rlpx, p2p_types, bootnodes],
  ./discoveryv4/enode,
  ./eth1_discovery

export
  p2p_types, rlpx, enode, ForkIdProc, CompatibleForkIdProc

logScope:
  topics = "p2p"

type
  ForkIdProcs* = object
    forkId*: ForkIdProc
    compatibleForkId*: CompatibleForkIdProc

proc newEthereumNode*(
    keys: KeyPair,
    address: Address,
    networkId: NetworkId,
    clientId = "nim-eth-p2p",
    minPeers = 10,
    bootstrapNodes = BootstrapNodes(),
    bindUdpPort: Port,
    bindTcpPort: Port,
    bindIp = IPv6_any(),
    rng = newRng(),
    forkIdProcs = ForkIdProcs()): EthereumNode =

  if rng == nil: # newRng could fail
    raiseAssert "Cannot initialize RNG"

  let
    discovery = Eth1Discovery.new(
      keys.seckey, address, bootstrapNodes, bindUdpPort, bindIp, rng, forkIdProcs.compatibleForkId)
    node = EthereumNode(
      keys: keys,
      networkId: networkId,
      clientId: clientId,
      address: address,
      connectionState: ConnectionState.None,
      bindIp: bindIp,
      bindPort: bindTcpPort,
      rng: rng,
    )
  node.peerPool = newPeerPool[EthereumNode](
    node, discovery, minPeers = minPeers, forkId = forkIdProcs.forkId)
  node

proc processIncoming(server: StreamServer,
                     remote: StreamTransport): Future[void] {.async: (raises: []).} =
  try:
    var node = getUserData[EthereumNode](server)
    let peer = await node.rlpxAccept(remote)
    if not peer.isNil:
      trace "Connection established (incoming)", peer
      if node.peerPool != nil:
        node.peerPool.connectingNodes.excl(peer.remote)
        node.peerPool.addPeer(peer)
  except EthP2PError as exc:
    error "processIncoming", msg=exc.msg
  except CancelledError:
    discard

proc listeningAddress*(node: EthereumNode): ENode =
  node.toENode()

proc startListening*(node: EthereumNode) {.raises: [TransportOsError].} =
  # TODO: allow binding to both IPv4 & IPv6
  let ta = initTAddress(node.bindIp, node.bindPort)
  if node.listeningServer == nil:
    node.listeningServer = createStreamServer(ta, processIncoming,
                                              {ReuseAddr},
                                              udata = cast[pointer](node))
  node.listeningServer.start()
  info "RLPx listener up", self = node.listeningAddress

proc connectToNetwork*(
    node: EthereumNode,
    startListening = true,
    enableDiscV4 = true,
    enableDiscV5 = true) =
  doAssert node.connectionState == ConnectionState.None

  node.connectionState = Connecting

  if startListening:
    try:
      p2p.startListening(node)
    except TransportOsError as exc:
      fatal "Cannot start listening server", msg=exc.msg
      quit(QuitFailure)

  if enableDiscV4 or enableDiscV5:
    node.peerPool.start(enableDiscV4, enableDiscV5)
  else:
    info "Discovery disabled"

proc stopListening*(node: EthereumNode) =
  try:
    node.listeningServer.stop()
  except TransportOsError as exc:
    error "Failure when try to stop stop listening server", msg=exc.msg

iterator peers*(node: EthereumNode): Peer =
  for peer in node.peerPool.peers:
    yield peer

iterator peers*(node: EthereumNode, Protocol: type): Peer =
  for peer in node.peerPool.peers(Protocol):
    yield peer

proc connectToNode*(node: EthereumNode, n: Node) {.async: (raises: [CancelledError]).} =
  await node.peerPool.connectToNode(n)

proc connectToNode*(node: EthereumNode, n: ENode) {.async: (raises: [CancelledError]).} =
  await node.peerPool.connectToNode(n)

func numPeers*(node: EthereumNode): int =
  node.peerPool.numPeers

proc closeWait*(node: EthereumNode) {.async: (raises: []).} =
  node.stopListening()
  await node.listeningServer.closeWait()
  await node.peerPool.closeWait()

proc addCapability*(node: EthereumNode,
                    p: ProtocolInfo,
                    networkState: RootRef = nil) =
  doAssert node.connectionState == ConnectionState.None

  let pos = lowerBound(node.protocols, p, rlpx.cmp)
  node.protocols.insert(p, pos)
  node.capabilities.insert(p.capability, pos)

  if p.networkStateInitializer != nil and networkState.isNil:
    node.networkStates[p.index] = p.networkStateInitializer(node)

  if networkState.isNil.not:
    node.networkStates[p.index] = networkState

template addCapability*(node: EthereumNode,
                        Protocol: type,
                        networkState: untyped) =
  mixin NetworkState
  type
    ParamType = type(networkState)

  when ParamType isnot Protocol.NetworkState:
    const errMsg = "`$1` is not compatible with `$2`" % [
      name(ParamType), name(Protocol.NetworkState)]
    {. error: errMsg .}

  addCapability(node, Protocol.protocolInfo,
    cast[RootRef](networkState))
