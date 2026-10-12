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
  std/[tables, typetraits, strutils, net],
  chronos, chronos/timer, chronicles,
  eth/common/keys,
  eth/enode/enode,
  results,
  ./[peer_pool, rlpx, p2p_types, bootnodes],
  ./eth1_discovery

export
  p2p_types, rlpx, enode, ForkIdProc, CompatibleForkIdProc

logScope:
  topics = "p2p"

const
  connectLoopSleep = chronos.milliseconds(2000)
  updateLoopSleep = chronos.seconds(15)
  maxConcurrentConnectionRequests = 40

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
  node.peerPool = newPeerPool[EthereumNode](node, maxPeers = maxPeers)
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

# This code is loosely based on code from nimbus-eth2;
# see eth2_network.nim and search for connQueue.
proc createConnectionWorker(
    node: EthereumNode, workerId: int
) {.async: (raises: [CancelledError]).} =
  trace "Connection worker started", workerId = workerId
  while true:
    let n = await node.connQueue.popFirst()
    await node.peerPool.connectToNode(n)

proc lookupPeers(node: EthereumNode) {.async: (raises: [CancelledError]).} =
  ## Look for more peers while the pool has room for them and hand the nodes
  ## that discovery came up with to the connection workers.
  if node.peerPool.dialTargetReached():
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
    debug "Amount of peers", amount = node.peerPool.numPeers

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

proc connectToNode*(node: EthereumNode, n: Node) {.async: (raises: [CancelledError]).} =
  await node.peerPool.connectToNode(n)

proc connectToNode*(node: EthereumNode, n: ENode) {.async: (raises: [CancelledError]).} =
  await node.peerPool.connectToNode(n)

func numPeers*(node: EthereumNode): int =
  node.peerPool.numPeers

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
