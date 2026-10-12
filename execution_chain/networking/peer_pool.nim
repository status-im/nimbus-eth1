# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, tables, times, sets],
  chronos, chronicles,
  eth/common/base,
  ./p2p_metrics,
  ./[p2p_node, p2p_peers]

export sets, tables, base, p2p_node

logScope:
  topics = "p2p peer_pool"

type
  SeenNode = object
    nodeId: NodeId
    stamp: chronos.Moment

  # Usually Network generic param is instantiated with EthereumNode
  PeerPoolRef*[Network] = ref object
    network: Network
    maxPeers*: int
      ## Hard limit on the number of connected peers, incoming and outgoing
      ## alike - see `isFull`
    dialTarget*: int
      ## Number of peers up to which we actively dial out. This is deliberately
      ## lower than `maxPeers` so that the dialer cannot fill every slot and
      ## leave the node unreachable for incoming connections.
    seenTable: Table[NodeId, SeenNode]
    connectingNodes*: HashSet[Node]
    connectedNodes*: Table[Node, PeerRef[Network]]
    observers*: Table[int, PeerObserverRef[Network]]

  PeerObserverRef*[Network] = object
    onPeerConnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    onPeerDisconnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    protocols*: seq[ProtocolInfoRef[PeerRef[Network], Network]]

const
  defaultMaxPeers* = 25
    ## Fallback when `--max-peers` is not given. Exported so that `conf.nim`
    ## and the `newPeerPool` / `newEthereumNode` defaults cannot drift apart.

  inboundSlotDivisor = 3
    ## One in this many peer slots is kept free for incoming connections.

  SeenTableTimeDeadPeer = chronos.minutes(10)
    ## Period of time for dead / unreachable peers.

  SeenTableTimeUselessPeer = chronos.hours(24)
    ## Period of time for Useless peers, either because of no matching
    ## capabilities or on an irrelevant network.

  SeenTableTimeProtocolError = chronos.minutes(30)
    ## Period of time for peers with a protocol error.

  SeenTableTimeReconnect = chronos.minutes(5)
    ## Period of time for peers with general disconnections / transport errors.

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

func isFull*(p: PeerPoolRef): bool =
  ## `true` when the pool holds `maxPeers` peers and no further connection,
  ## incoming or outgoing, may be established.
  p.connectedNodes.len >= p.maxPeers

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

  if p.isFull:
    trace "Peer limit reached, not dialing", remote, maxPeers = p.maxPeers
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

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

func newPeerPool*[Network](
    network: Network, maxPeers = defaultMaxPeers): PeerPoolRef[Network] =
  let limit = max(1, maxPeers)
  PeerPoolRef[Network](
    network: network,
    maxPeers: limit,
    dialTarget: max(1, limit - limit div inboundSlotDivisor),
    connectedNodes: initTable[Node, PeerRef[Network]](),
    connectingNodes: initHashSet[Node](),
    observers: initTable[int, PeerObserverRef[Network]](),
  )

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

func dialTargetReached*(p: PeerPoolRef): bool =
  p.connectedNodes.len >= p.dialTarget

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
