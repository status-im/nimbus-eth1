# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/[tables, times, typetraits, strutils, net, sets],
  chronos, chronos/timer, chronicles,
  eth/common/keys,
  eth/enode/enode,
  results,
  ./[peer_pool, rlpx, p2p_types, p2p_metrics, bootnodes],
  ./eth1_discovery

export
  p2p_types, rlpx, enode, ForkIdProc, CompatibleForkIdProc

logScope:
  topics = "p2p"

const
  connectLoopSleep = chronos.milliseconds(2000)
  updateLoopSleep = chronos.seconds(15)
  maxConcurrentConnectionRequests = 40

  SeenTableTimeDeadPeer = chronos.minutes(10)
    ## Period of time for dead / unreachable peers.

  SeenTableTimeUselessPeer = chronos.hours(24)
    ## Period of time for Useless peers, either because of no matching
    ## capabilities or on an irrelevant network.

  SeenTableTimeProtocolError = chronos.minutes(30)
    ## Period of time for peers with a protocol error.

  SeenTableTimeReconnect = chronos.minutes(5)
    ## Period of time for peers with general disconnections / transport errors.

type
  ForkIdProcs* = object
    forkId*: ForkIdProc
    compatibleForkId*: CompatibleForkIdProc

proc newEthereumNode*(
    keys: KeyPair,
    enrIp: Opt[IpAddress],
    enrTcpPort, enrUdpPort: Opt[Port],
    networkId: NetworkId,
    clientId = "nim-eth-p2p",
    maxPeers = defaultMaxPeers,
    bootstrapNodes = BootstrapNodes(),
    bindUdpPort: Port,
    bindTcpPort: Port,
    bindIp = IPv6_any(),
    rng = newRng(),
    enableDiscV5 = true,
    forkIdProcs = ForkIdProcs()): EthereumNode =

  if rng == nil: # newRng could fail
    raiseAssert "Cannot initialize RNG"

  let
    address = enode.Address(
      ip: enrIp.valueOr(bindIp),
      tcpPort: enrTcpPort.valueOr(bindTcpPort),
      udpPort: enrUdpPort.valueOr(bindUdpPort),
    )
    discovery =
      if enableDiscV5:
        Eth1Discovery.new(
          keys.seckey, enrIp, enrTcpPort, enrUdpPort, bootstrapNodes,
          bindUdpPort, bindIp, rng, forkIdProcs.compatibleForkId)
      else:
        nil
    node = EthereumNode(
      keys: keys,
      networkId: networkId,
      clientId: clientId,
      address: address,
      connectionState: ConnectionState.None,
      bindIp: bindIp,
      bindPort: bindTcpPort,
      discovery: discovery,
      forkId: forkIdProcs.forkId,
      rng: rng,
    )
  node.peerPool = PeerPool.new(maxPeers = maxPeers)
  node

proc processIncoming(server: StreamServer,
                     remote: StreamTransport): Future[void] {.async: (raises: []).} =
  try:
    var node = getUserData[EthereumNode](server)
    let peer = await node.rlpxAccept(remote)
    if not peer.isNil and node.peerPool != nil:
      node.connectingNodes.excl(peer.remote)
      if node.peerPool.addPeer(peer):
        trace "Connection established (incoming)", peer
      else:
        trace "No room left, dropping incoming peer", peer
        await peer.disconnect(TooManyPeers, notifyRemote = true)
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

proc isSeen(node: EthereumNode, nodeId: NodeId): bool =
  ## Returns ``true`` if ``nodeId`` present in the seen table and the time
  ## period has not yet expired.
  let currentTime = now(chronos.Moment)
  if nodeId notin node.seenTable:
    false
  else:
    let item = try: node.seenTable[nodeId]
    except KeyError: raiseAssert "checked with notin"
    if currentTime >= item.stamp:
      # Peer is in the seen table, but the time period has expired.
      node.seenTable.del(nodeId)
      false
    else:
      true

proc addSeen(node: EthereumNode, nodeId: NodeId, period: chronos.Duration) =
  ## Adds peer with NodeId ``nodeId`` to the seen table with timeout ``period``.
  let item = SeenNode(nodeId: nodeId, stamp: now(chronos.Moment) + period)
  withValue(node.seenTable, nodeId, entry) do:
    if entry.stamp < item.stamp:
      entry.stamp = item.stamp
  do:
    node.seenTable[nodeId] = item

proc dialPeer(
    node: EthereumNode, remote: Node
): Future[Peer] {.async: (raises: [CancelledError]).} =
  ## Dial the given remote and return the peer when the handshake succeeded.
  ## Returns nil if the remote is unreachable, times out or is useless.
  if remote in node.peerPool:
    trace "skipping_connection_to_already_connected_peer", remote
    return nil

  if remote in node.connectingNodes:
    return nil

  if node.isSeen(remote.id):
    return nil

  if node.peerPool.isFull:
    trace "Peer limit reached, not dialing", remote,
      maxPeers = node.peerPool.maxPeers
    return nil

  trace "Connecting to node", remote
  node.connectingNodes.incl(remote)
  let res =
    try:
      await node.rlpxConnect(remote)
    except CancelledError as exc:
      node.connectingNodes.excl(remote)
      raise exc
  node.connectingNodes.excl(remote)

  if res.isOk():
    rlpx_connect_success.inc()
    return res.get()

  rlpx_connect_failure.inc()
  rlpx_connect_failure.inc(labelValues = [$res.error])
  case res.error()
  of UselessRlpxPeerError:
    node.addSeen(remote.id, SeenTableTimeUselessPeer)
  of TransportConnectError:
    node.addSeen(remote.id, SeenTableTimeDeadPeer)
  of RlpxHandshakeError, ProtocolError, InvalidIdentityError:
    node.addSeen(remote.id, SeenTableTimeProtocolError)
  of RlpxHandshakeTransportError,
      P2PHandshakeError,
      P2PTransportError,
      PeerDisconnectedError,
      TooManyPeersError:
    node.addSeen(remote.id, SeenTableTimeReconnect)

  nil

proc connectToNode*(
    node: EthereumNode, n: Node) {.async: (raises: [CancelledError]).} =
  let peer = await node.dialPeer(n)
  if not peer.isNil:
    if node.peerPool.addPeer(peer):
      trace "Connection established (outgoing)", peer
    else:
      trace "No room left, dropping dialed peer", peer
      await peer.disconnect(TooManyPeers, notifyRemote = true)

proc connectToNode*(
    node: EthereumNode, n: ENode) {.async: (raises: [CancelledError]).} =
  await node.connectToNode(newNode(n))

# This code is loosely based on code from nimbus-eth2;
# see eth2_network.nim and search for connQueue.
proc createConnectionWorker(
    node: EthereumNode, workerId: int
) {.async: (raises: [CancelledError]).} =
  trace "Connection worker started", workerId = workerId
  while true:
    let n = await node.connQueue.popFirst()
    await node.connectToNode(n)

proc lookupPeers(node: EthereumNode) {.async: (raises: [CancelledError]).} =
  ## Look for more peers while the pool has room for them and hand the nodes
  ## that discovery came up with to the connection workers.
  if node.peerPool.isFull:
    return

  for n in await node.discovery.lookupRandomNode():
    await node.connQueue.addLast(n)

func updateForkId(node: EthereumNode) =
  ## Keep the advertised ENR `eth` entry in sync with the chain, without
  ## rewriting the record on every tick.
  if node.forkId.isNil:
    return

  let forkId = node.forkId()
  if node.lastForkId == forkId:
    return

  node.discovery.updateForkId(forkId)
  node.lastForkId = forkId

proc runDiscovery(node: EthereumNode) {.async: (raises: [CancelledError]).} =
  trace "Running discovery loop..."

  # initial cycle
  node.updateForkId()
  node.discovery.start()
  await node.lookupPeers()

  var
    connectTimer: Future[void].Raising([CancelledError])
    updateTimer: Future[void].Raising([CancelledError])

  while true:
    debug "Amount of peers", amount = node.peerPool.len

    # Create or replenish timer
    if connectTimer.isNil or connectTimer.finished:
      connectTimer = sleepAsync(connectLoopSleep)

    if updateTimer.isNil or updateTimer.finished:
      updateTimer = sleepAsync(updateLoopSleep)

    let res = await race(connectTimer, updateTimer)

    if res == connectTimer:
      await node.lookupPeers()

    if res == updateTimer:
      node.updateForkId()

proc startDiscovery(node: EthereumNode) =
  try:
    node.discovery.open()
  except TransportOsError as exc:
    fatal "Cannot start discovery protocol", msg=exc.msg
    quit(QuitFailure)

  node.connQueue = newAsyncQueue[Node](maxConcurrentConnectionRequests)
  node.connWorkers = newSeqOfCap[Future[void].Raising([CancelledError])](
    maxConcurrentConnectionRequests)
  for i in 0 ..< maxConcurrentConnectionRequests:
    node.connWorkers.add createConnectionWorker(node, i)

  node.discoveryLoop = runDiscovery(node)

proc stopDiscovery(node: EthereumNode) {.async: (raises: []).} =
  if node.discoveryLoop.isNil:
    return

  var futures = newSeqOfCap[Future[void]](node.connWorkers.len + 1)
  futures.add node.discoveryLoop.cancelAndWait()
  for worker in node.connWorkers:
    futures.add worker.cancelAndWait()
  await noCancel(allFutures(futures))

  node.discoveryLoop = nil
  node.connWorkers.reset()
  await node.discovery.closeWait()

proc connectToNetwork*(
    node: EthereumNode,
    startListening = true) =
  doAssert node.connectionState == ConnectionState.None

  node.connectionState = Connecting

  if startListening:
    try:
      p2p.startListening(node)
    except TransportOsError as exc:
      fatal "Cannot start listening server", msg=exc.msg
      quit(QuitFailure)

  if node.discovery != nil:
    node.startDiscovery()
  else:
    info "Discovery disabled"

proc stopListening*(node: EthereumNode) =
  try:
    if not node.listeningServer.isNil():
      node.listeningServer.stop()
  except TransportOsError as exc:
    error "Failure when try to stop stop listening server", msg=exc.msg

iterator peers*(node: EthereumNode): Peer =
  for peer in node.peerPool.peers:
    yield peer

iterator peers*(node: EthereumNode, Protocol: type): Peer =
  for peer in node.peerPool.peers(Protocol):
    yield peer

func numPeers*(node: EthereumNode): int =
  node.peerPool.len

proc closeWait*(node: EthereumNode) {.async: (raises: []).} =
  node.stopListening()
  if not node.listeningServer.isNil():
    await node.listeningServer.closeWait()
  await node.stopDiscovery()

proc addCapability*(node: EthereumNode,
                    p: ProtocolInfo,
                    networkState: RootRef = nil) =
  doAssert node.connectionState == ConnectionState.None

  # Find insertion index `pos`.
  #
  # The array `node.protocols[]` is sorted by the capability fields with
  # * <name>    -- sorted implicitely given by the registry order
  # * <version> -- sorted numerically by highest version first
  #
  var pos = node.protocols.len
  block findInsertionIndex:
    for inx in 0 ..< node.protocols.len:
      # Find clustered protocol family names
      if p.capability.name == node.protocols[inx].capability.name:

        # Get insertion point right before the next smaller version
        pos = inx
        while pos < node.protocols.len:
          if node.protocols[pos].capability.name != p.capability.name or
             node.protocols[pos].capability.version < p.capability.version:
            break findInsertionIndex
          if node.protocols[pos].capability.version == p.capability.version:
            raiseAssert "Duplicate protocol registry for " & $p.capability
          pos.inc
        break findInsertionIndex

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
