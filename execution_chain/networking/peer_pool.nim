# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# PeerPoolRef attempts to keep connections to at least min_peers
# on the given network.

{.push raises: [].}

import
  std/[os, tables, times, sets],
  chronos, chronicles,
  ./p2p_metrics,
  ./[eth1_discovery, p2p_peers]

logScope:
  topics = "p2p peer_pool"

type
  SeenNode = object
    nodeId: NodeId
    stamp: chronos.Moment

  WorkerFuture = Future[void].Raising([CancelledError])

  # Usually Network generic param is instantiated with EthereumNode
  PeerPoolRef*[Network] = ref object
    network: Network
    minPeers: int
    lastLookupTime: float
    connQueue: AsyncQueue[Node]
    seenTable: Table[NodeId, SeenNode]
    running: bool
    discovery: Eth1Discovery
    workers: seq[WorkerFuture]
    connectingNodes*: HashSet[Node]
    connectedNodes*: Table[Node, PeerRef[Network]]
    observers*: Table[int, PeerObserverRef[Network]]

  PeerObserverRef*[Network] = object
    onPeerConnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    onPeerDisconnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    protocols*: seq[ProtocolInfoRef[PeerRef[Network], Network]]

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

#------------------------------------------------------------------------------
# Private functions
#------------------------------------------------------------------------------

proc isSeen(p: PeerPoolRef, nodeId: NodeId): bool =
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
    p: PeerPoolRef, nodeId: NodeId, period: chronos.Duration) =
  ## Adds peer with NodeId ``nodeId`` to SeenTable and timeout ``period``.
  let item = SeenNode(nodeId: nodeId, stamp: now(chronos.Moment) + period)
  withValue(p.seenTable, nodeId, entry) do:
    if entry.stamp < item.stamp:
      entry.stamp = item.stamp
  do:
    p.seenTable[nodeId] = item

proc connect[Network](p: PeerPoolRef[Network], remote: Node): Future[PeerRef[Network]] {.async: (raises: [CancelledError]).} =
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

proc connectToNode*(p: PeerPoolRef, n: Node) {.async: (raises: [CancelledError]).}

# This code is loosely based on code from nimbus-eth2;
# see eth2_network.nim and search for connQueue.
proc createConnectionWorker(p: PeerPoolRef, workerId: int): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Connection worker started", workerId = workerId
  while true:
    let n = await p.connQueue.popFirst()
    await connectToNode(p, n)

proc maybeConnectToMorePeers(p: PeerPoolRef) {.async: (raises: [CancelledError]).} =
  ## Connect to more peers if we're not yet connected to at least self.minPeers.
  if p.connectedNodes.len >= p.minPeers:
    # debug "pool already connected to enough peers (sleeping)", count = p.connectedNodes
    return

  if p.lastLookupTime + lookupInterval < epochTime():
    # Add nodes to connQueue from discovery protocol,
    # to be later processed by connection worker
    await p.discovery.lookupRandomNode(p.connQueue)
    p.lastLookupTime = epochTime()

  let debugEnode = getEnv("ETH_DEBUG_ENODE")
  if debugEnode.len != 0:
    await p.connectToNode(newNode(debugEnode))

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
  if p.connectedNodes.len > 0:
    return

  let n = p.discovery.getRandomBootnode().valueOr:
    return
  await p.connectToNode(n)

proc run(p: PeerPoolRef) {.async: (raises: [CancelledError]).} =
  trace "Running PeerPool..."

  await p.discovery.start()
  p.running = true
  while p.running:
    debug "Amount of peers", amount = p.connectedNodes.len()
    await p.maybeConnectToMorePeers()
    await sleepAsync(connectLoopSleep)

#------------------------------------------------------------------------------
# Private functions
#------------------------------------------------------------------------------

func newPeerPool*[Network](
    network: Network,
    discovery: Eth1Discovery, minPeers = 10): PeerPoolRef[Network] =
  new result
  result.network = network
  result.minPeers = minPeers
  result.discovery = discovery
  result.connQueue = newAsyncQueue[Node](maxConcurrentConnectionRequests)
  result.connectedNodes = initTable[Node, PeerRef[Network]]()
  result.connectingNodes = initHashSet[Node]()
  result.observers = initTable[int, PeerObserverRef[Network]]()

proc addObserver*(p: PeerPoolRef, observerId: int, observer: PeerObserverRef) =
  doAssert(observerId notin p.observers)
  p.observers[observerId] = observer
  if not observer.onPeerConnected.isNil:
    for peer in p.connectedNodes.values:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

func delObserver*(p: PeerPoolRef, observerId: int) =
  p.observers.del(observerId)

proc addObserver*(p: PeerPoolRef, observerId: ref, observer: PeerObserverRef) =
  p.addObserver(cast[int](observerId), observer)

func delObserver*(p: PeerPoolRef, observerId: ref) =
  p.delObserver(cast[int](observerId))

template addProtocol*(observer: PeerObserverRef, Protocol: type) =
  observer.protocols.add Protocol.protocolInfo

func len*(p: PeerPoolRef): int = p.connectedNodes.len

iterator peers*[Network](p: PeerPoolRef[Network]): PeerRef[Network] =
  for remote, peer in p.connectedNodes:
    yield peer

iterator peers*[Network](p: PeerPoolRef[Network], Protocol: type): PeerRef[Network] =
  for peer in p.peers:
    if peer.supports(Protocol):
      yield peer

func numPeers*(p: PeerPoolRef): int =
  p.connectedNodes.len

func contains*(p: PeerPoolRef, n: ENode): bool =
  for remote, _ in p.connectedNodes:
    if remote.node == n:
      return true

func contains*(p: PeerPoolRef, n: Node): bool =
  n in p.connectedNodes

func contains*(p: PeerPoolRef, n: PeerRef): bool =
  n.remote in p.connectedNodes

proc addPeer*(pool: PeerPoolRef, peer: PeerRef) {.gcsafe.} =
  doAssert(peer.remote notin pool.connectedNodes)
  pool.connectedNodes[peer.remote] = peer
  rlpx_connected_peers.inc()
  for observer in pool.observers.values:
    if not observer.onPeerConnected.isNil:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

proc connectToNode*(p: PeerPoolRef, n: Node) {.async: (raises: [CancelledError]).} =
  let peer = await p.connect(n)
  if not peer.isNil:
    trace "Connection established (outgoing)", peer
    p.addPeer(peer)

proc connectToNode*(p: PeerPoolRef, n: ENode) {.async: (raises: [CancelledError]).} =
  await p.connectToNode(newNode(n))

proc start*(p: PeerPoolRef, enableDiscV4: bool, enableDiscV5: bool) =
  if p.running:
    return

  try:
    p.discovery.open(enableDiscV4, enableDiscV5)
  except TransportOsError as exc:
    error "Cannot start discovery protocol", msg=exc.msg
    return

  var workers = newSeqOfCap[WorkerFuture](maxConcurrentConnectionRequests+1)
  for i in 0 ..< maxConcurrentConnectionRequests:
    workers.add createConnectionWorker(p, i)

  workers.add p.run()
  p.workers = move(workers)

proc closeWait*(p: PeerPoolRef) {.async: (raises: []).} =
  if not p.running:
    return
  p.running = false
  var futures = newSeqOfCap[Future[void]](p.workers.len)
  for worker in p.workers:
    futures.add worker.cancelAndWait()
  await noCancel(allFutures(futures))
  await p.discovery.closeWait()
