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
  std/[tables, algorithm, random, typetraits, strutils, net],
  chronos, chronos/timer, chronicles,
  eth/common/keys,
  results,
  ./[discoveryv4, peer_pool, rlpx, p2p_types]

export
  p2p_types, rlpx, enode, kademlia

logScope:
  topics = "p2p"

proc newEthereumNode*(
    keys: KeyPair,
    address: Address,
    networkId: NetworkId,
    clientId = "nim-eth-p2p",
    minPeers = 10,
    bootstrapNodes: seq[ENode] = @[],
    bindUdpPort: Port,
    bindTcpPort: Port,
    bindIp = IPv6_any(),
    rng = newRng()): EthereumNode =

  if rng == nil: # newRng could fail
    raiseAssert "Cannot initialize RNG"

  new result
  result.keys = keys
  result.networkId = networkId
  result.clientId = clientId
  result.protocols.newSeq 0
  result.capabilities.newSeq 0
  result.address = address
  result.connectionState = ConnectionState.None
  result.bindIp = bindIp
  result.bindPort = bindTcpPort
  result.rng = rng

  let discv4 = newDiscoveryV4(
    keys.seckey, address, bootstrapNodes, bindUdpPort, bindIp, rng)

  result.peerPool = newPeerPool[EthereumNode](
    result, discv4, minPeers = minPeers)

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
  except CatchableError as exc:
    error "processIncoming", msg=exc.msg

proc listeningAddress*(node: EthereumNode): ENode =
  node.toENode()

proc startListening*(node: EthereumNode) {.raises: [CatchableError].} =
  # TODO: allow binding to both IPv4 & IPv6
  let ta = initTAddress(node.bindIp, node.bindPort)
  if node.listeningServer == nil:
    node.listeningServer = createStreamServer(ta, processIncoming,
                                              {ReuseAddr},
                                              udata = cast[pointer](node))
  node.listeningServer.start()
  info "RLPx listener up", self = node.listeningAddress

proc connectToNetwork*(
    node: EthereumNode, startListening = true,
    enableDiscovery = true, waitForPeers = true) {.async.} =
  doAssert node.connectionState == ConnectionState.None

  node.connectionState = Connecting

  if startListening:
    p2p.startListening(node)

  if enableDiscovery:
    node.peerPool.discv4.open()
    await node.peerPool.discv4.bootstrap()
    node.peerPool.start()
  else:
    info "Discovery disabled"

  while node.peerPool.connectedNodes.len == 0 and waitForPeers:
    trace "Waiting for more peers", peers = node.peerPool.connectedNodes.len
    await sleepAsync(500.milliseconds)

proc stopListening*(node: EthereumNode) {.raises: [CatchableError].} =
  node.listeningServer.stop()

iterator peers*(node: EthereumNode): Peer =
  for peer in node.peerPool.peers:
    yield peer

iterator peers*(node: EthereumNode, Protocol: type): Peer =
  for peer in node.peerPool.peers(Protocol):
    yield peer

proc connectToNode*(node: EthereumNode, n: Node) {.async.} =
  await node.peerPool.connectToNode(n)

proc connectToNode*(node: EthereumNode, n: ENode) {.async.} =
  await node.peerPool.connectToNode(n)

func numPeers*(node: EthereumNode): int =
  node.peerPool.numPeers

proc closeWait*(node: EthereumNode) {.async.} =
  node.stopListening()
  await node.listeningServer.closeWait()

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
