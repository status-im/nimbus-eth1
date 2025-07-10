# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# PeerPool attempts to keep connections to at least min_peers
# on the given network.

{.push raises: [].}

import
  std/[os, tables, times, random, options],
  chronos, chronicles,
  ./[discoveryv4, rlpx, p2p_types]

logScope:
  topics = "p2p peer_pool"


const
  lookupInterval = 5
  connectLoopSleep = chronos.milliseconds(2000)
  maxConcurrentConnectionRequests = 40
  sleepBeforeTryingARandomBootnode = chronos.milliseconds(3000)

  ## Period of time for dead / unreachable peers.
  SeenTableTimeDeadPeer = chronos.minutes(10)
  ## Period of time for Useless peers, either because of no matching
  ## capabilities or on an irrelevant network.
  SeenTableTimeUselessPeer = chronos.hours(24)
  ## Period of time for peers with a protocol error.
  SeenTableTimeProtocolError = chronos.minutes(30)
  ## Period of time for peers with general disconnections / transport errors.
  SeenTableTimeReconnect = chronos.minutes(5)

proc isSeen(p: PeerPool, nodeId: NodeId): bool =
  ## Returns ``true`` if ``nodeId`` present in SeenTable and time period is not
  ## yet expired.
  let currentTime = now(chronos.Moment)
  if nodeId notin p.seenTable:
    false
  else:
    let item = try: p.seenTable[nodeId]
    except KeyError: raiseAssert "checked with notin"
    if currentTime >= item.stamp:
      # Peer is in SeenTable, but the time period has expired.
      p.seenTable.del(nodeId)
      false
    else:
      true

proc addSeen(
    p: PeerPool, nodeId: NodeId, period: chronos.Duration) =
  ## Adds peer with NodeId ``nodeId`` to SeenTable and timeout ``period``.
  let item = SeenNode(nodeId: nodeId, stamp: now(chronos.Moment) + period)
  withValue(p.seenTable, nodeId, entry) do:
    if entry.stamp < item.stamp:
      entry.stamp = item.stamp
  do:
    p.seenTable[nodeId] = item

func newPeerPool*(
    network: EthereumNode, networkId: NetworkId, keyPair: KeyPair,
    discovery: DiscoveryProtocol, clientId: string, minPeers = 10): PeerPool =
  new result
  result.network = network
  result.keyPair = keyPair
  result.minPeers = minPeers
  result.networkId = networkId
  result.discovery = discovery
  result.connQueue = newAsyncQueue[Node](maxConcurrentConnectionRequests)
  result.connectedNodes = initTable[Node, Peer]()
  result.connectingNodes = initHashSet[Node]()
  result.observers = initTable[int, PeerObserver]()

iterator nodesToConnect(p: PeerPool): Node =
  for node in p.discovery.randomNodes(p.minPeers):
    if node notin p.discovery.bootstrapNodes:
      yield node

proc addObserver*(p: PeerPool, observerId: int, observer: PeerObserver) =
  doAssert(observerId notin p.observers)
  p.observers[observerId] = observer
  if not observer.onPeerConnected.isNil:
    for peer in p.connectedNodes.values:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

func delObserver*(p: PeerPool, observerId: int) =
  p.observers.del(observerId)

proc addObserver*(p: PeerPool, observerId: ref, observer: PeerObserver) =
  p.addObserver(cast[int](observerId), observer)

func delObserver*(p: PeerPool, observerId: ref) =
  p.delObserver(cast[int](observerId))

template addProtocol*(observer: PeerObserver, Protocol: type) =
  observer.protocols.add Protocol.protocolInfo

proc stopAllPeers(p: PeerPool) {.async.} =
  debug "Stopping all peers ..."
  # TODO: ...
  # await asyncio.gather(
  #   *[peer.stop() for peer in self.connected_nodes.values()])

proc connect(p: PeerPool, remote: Node): Future[Peer] {.async.} =
  ## Connect to the given remote and return a Peer instance when successful.
  ## Returns nil if the remote is unreachable, times out or is useless.
  if remote in p.connectedNodes:
    trace "skipping_connection_to_already_connected_peer", remote
    return nil

  if remote in p.connectingNodes:
    # debug "skipping connection"
    return nil

  if p.isSeen(remote.id):
    return nil

  trace "Connecting to node", remote
  p.connectingNodes.incl(remote)
  let res = await p.network.rlpxConnect(remote)
  p.connectingNodes.excl(remote)

  # TODO: Probably should move all this logic to rlpx.nim
  if res.isOk():
    rlpx_connect_success.inc()
    return res.get()
  else:
    rlpx_connect_failure.inc()
    rlpx_connect_failure.inc(labelValues = [$res.error])
    case res.error():
    of UselessRlpxPeerError:
      p.addSeen(remote.id, SeenTableTimeUselessPeer)
    of TransportConnectError:
      p.addSeen(remote.id, SeenTableTimeDeadPeer)
    of RlpxHandshakeError, ProtocolError, InvalidIdentityError:
      p.addSeen(remote.id, SeenTableTimeProtocolError)
    of RlpxHandshakeTransportError,
        P2PHandshakeError,
        P2PTransportError,
        PeerDisconnectedError,
        TooManyPeersError:
      p.addSeen(remote.id, SeenTableTimeReconnect)

    return nil

proc lookupRandomNode(p: PeerPool) {.async.} =
  discard await p.discovery.lookupRandom()
  p.lastLookupTime = epochTime()

proc getRandomBootnode(p: PeerPool): Option[Node] =
  if p.discovery.bootstrapNodes.len != 0:
    result = option(p.discovery.bootstrapNodes.sample())

proc addPeer*(pool: PeerPool, peer: Peer) {.gcsafe.} =
  doAssert(peer.remote notin pool.connectedNodes)
  pool.connectedNodes[peer.remote] = peer
  rlpx_connected_peers.inc()
  for observer in pool.observers.values:
    if not observer.onPeerConnected.isNil:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

proc connectToNode*(p: PeerPool, n: Node) {.async.} =
  let peer = await p.connect(n)
  if not peer.isNil:
    trace "Connection established (outgoing)", peer
    p.addPeer(peer)

proc connectToNode*(p: PeerPool, n: ENode) {.async.} =
  await p.connectToNode(newNode(n))


# This code is loosely based on code from nimbus-eth2;
# see eth2_network.nim and search for connQueue.
proc createConnectionWorker(p: PeerPool, workerId: int): Future[void] {.async.} =
  trace "Connection worker started", workerId = workerId
  while true:
    let n = await p.connQueue.popFirst()
    await connectToNode(p, n)

    # # TODO: Consider changing connect() to raise an exception instead of
    # # returning None, as discussed in
    # # https://github.com/ethereum/py-evm/pull/139#discussion_r152067425
    # echo "Connecting to node: ", node
    # let peer = await p.connect(node)
    # if not peer.isNil:
    #   info "Successfully connected to ", peer
    #   ensureFuture peer.run(p)

    #   p.connectedNodes[peer.remote] = peer
    #   # for subscriber in self._subscribers:
    #   #   subscriber.register_peer(peer)
    #   if p.connectedNodes.len >= p.minPeers:
    #     return

proc startConnectionWorkerPool(p: PeerPool, workerCount: int) =
  for i in 0 ..< workerCount:
    asyncSpawn createConnectionWorker(p, i)

proc maybeConnectToMorePeers(p: PeerPool) {.async.} =
  ## Connect to more peers if we're not yet connected to at least self.minPeers.
  if p.connectedNodes.len >= p.minPeers:
    # debug "pool already connected to enough peers (sleeping)", count = p.connectedNodes
    return

  if p.lastLookupTime + lookupInterval < epochTime():
    asyncSpawn p.lookupRandomNode()

  let debugEnode = getEnv("ETH_DEBUG_ENODE")
  if debugEnode.len != 0:
    await p.connectToNode(newNode(debugEnode))
  else:
    for n in p.nodesToConnect():
      await p.connQueue.addLast(n)

    # The old version of the code (which did all the connection
    # attempts in serial, not parallel) actually *awaited* all
    # the connection attempts before reaching the code at the
    # end of this proc that tries a random bootnode. Should
    # that still be what happens? I don't think so; one of the
    # reasons we're doing the connection attempts concurrently
    # is because sometimes the attempt takes a long time. Still,
    # it seems like we should give the many connection attempts
    # a *chance* to complete before moving on to trying a random
    # bootnode. So let's try just waiting a few seconds. (I am
    # really not sure this makes sense.)
    #
    # --Adam, Dec. 2022
    await sleepAsync(sleepBeforeTryingARandomBootnode)

  # In some cases (e.g ROPSTEN or private testnets), the discovery table might
  # be full of bad peers, so if we can't connect to any peers we try a random
  # bootstrap node as well.
  if p.connectedNodes.len == 0 and (let n = p.getRandomBootnode(); n.isSome):
    await p.connectToNode(n.get())

proc run(p: PeerPool) {.async.} =
  trace "Running PeerPool..."
  p.running = true
  p.startConnectionWorkerPool(maxConcurrentConnectionRequests)
  while p.running:

    debug "Amount of peers", amount = p.connectedNodes.len()
    var dropConnections = false
    try:
      await p.maybeConnectToMorePeers()
    except CatchableError as e:
      # Most unexpected errors should be transient, so we log and restart from
      # scratch.
      error "Unexpected PeerPool error, restarting",
        err = e.msg, stackTrace = e.getStackTrace()
      dropConnections = true

    if dropConnections:
      await p.stopAllPeers()

    await sleepAsync(connectLoopSleep)

proc start*(p: PeerPool) =
  if not p.running:
    asyncSpawn p.run()

func len*(p: PeerPool): int = p.connectedNodes.len

iterator peers*(p: PeerPool): Peer =
  for remote, peer in p.connectedNodes:
    yield peer

iterator peers*(p: PeerPool, Protocol: type): Peer =
  for peer in p.peers:
    if peer.supports(Protocol):
      yield peer

func numPeers*(p: PeerPool): int =
  p.connectedNodes.len

func contains*(p: PeerPool, n: ENode): bool =
  for remote, _ in p.connectedNodes:
    if remote.node == n:
      return true

func contains*(p: PeerPool, n: Node): bool =
  n in p.connectedNodes

func contains*(p: PeerPool, n: Peer): bool =
  n.remote in p.connectedNodes
