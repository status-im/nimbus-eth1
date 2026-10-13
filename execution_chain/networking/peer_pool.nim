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
  std/tables,
  eth/common/base,
  ./p2p_metrics,
  ./[p2p_node, p2p_peers]

export tables, base, p2p_node

declareGauge nec_p2p_inbound_peers,
  "Number of connected peers in the pool that dialed us"

declareGauge nec_p2p_outbound_peers,
  "Number of connected peers in the pool that we dialed"

type
  # Usually Network generic param is instantiated with EthereumNode
  PeerPoolRef*[Network] = ref object
    maxPeers: int
      ## Hard limit on the number of connected peers, incoming and outgoing
      ## alike - see `isFull`
    maxInbound: int
      ## Hard limit on incoming connections. Outgoing connections have no limit
      ## of their own and can use what is left of `maxPeers`.
      ##
      ## Without this limit the pool would eventually fill up with incoming
      ## peers only. The dialer stops once the pool is full, and a peer that
      ## behaves according to protocol will not be dropped as there is no
      ## peer scoring. Every free slot then goes to whoever dials in first,
      ## typically before the node manages to dial outbound. Keeping slots
      ## for our the node's dials makes the node harder to eclipse.
    numInbound: int
    connectedNodes: Table[Node, PeerRef[Network]]
    observers: Table[int, PeerObserverRef[Network]]

  PeerObserverRef*[Network] = object
    onPeerConnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    onPeerDisconnected*: proc(p: PeerRef[Network]) {.gcsafe, raises: [].}
    protocols*: seq[ProtocolInfoRef[PeerRef[Network], Network]]

const
  defaultMaxPeers* = 50
    ## Fallback when `--max-peers` is not given. Exported so that `conf.nim`
    ## and the `PeerPool.new` / `newEthereumNode` defaults cannot drift apart.

  outboundSlotDivisor = 3
    ## One in this many peer slots is kept free for outgoing connections.

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

func maxPeers*(p: PeerPoolRef): int =
  p.maxPeers

func isFull*(p: PeerPoolRef): bool =
  ## `true` when the pool holds `maxPeers` peers and no further connection,
  ## incoming or outgoing, may be established.
  p.connectedNodes.len >= p.maxPeers

func isInboundFull*(p: PeerPoolRef): bool =
  ## `true` when we cannot take another incoming connection, either because the
  ## pool is full or because incoming peers already use their share of it.
  p.isFull or p.numInbound >= p.maxInbound

func new*[Network](
    _: type PeerPoolRef[Network], maxPeers = defaultMaxPeers
): PeerPoolRef[Network] =
  let limit = max(1, maxPeers)
  PeerPoolRef[Network](
    maxPeers: limit,
    maxInbound: max(1, limit - limit div outboundSlotDivisor),
    connectedNodes: initTable[Node, PeerRef[Network]](),
    observers: initTable[int, PeerObserverRef[Network]](),
  )

proc addObserver(p: PeerPoolRef, observerId: int, observer: PeerObserverRef) =
  doAssert(observerId notin p.observers)
  p.observers[observerId] = observer
  if not observer.onPeerConnected.isNil:
    for peer in p.connectedNodes.values:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

func delObserver(p: PeerPoolRef, observerId: int) =
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

func contains*(p: PeerPoolRef, n: Node): bool =
  n in p.connectedNodes

proc addPeer*(pool: PeerPoolRef, peer: PeerRef): bool {.gcsafe.} =
  ## Add a peer whose handshake completed. Returns `false` when there is
  ## no room left, in which case the caller must disconnect it.
  ##
  ## Here the actual maxInbound and maxPeers check is applied. The ones in
  ## `dialPeer` and `rlpxAccept` run before the handshake, which means the
  ## slot can be taken  by the time the handshake is finished.
  if peer.remote in pool.connectedNodes:
    return false

  if pool.connectedNodes.len >= pool.maxPeers:
    return false

  if peer.inbound and pool.numInbound >= pool.maxInbound:
    return false

  pool.connectedNodes[peer.remote] = peer
  if peer.inbound:
    inc pool.numInbound
    nec_p2p_inbound_peers.inc()
  else:
    nec_p2p_outbound_peers.inc()
  rlpx_connected_peers.inc()

  for observer in pool.observers.values:
    if not observer.onPeerConnected.isNil:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerConnected(peer)

  true

proc removePeer*(pool: PeerPoolRef, peer: PeerRef) {.gcsafe.} =
  ## Drop a peer that is no longer connected. Tolerates peers that were never
  ## added: the remote may have disconnected first, racing our own teardown.
  if peer.remote.isNil or peer.remote notin pool.connectedNodes:
    return

  pool.connectedNodes.del(peer.remote)
  if peer.inbound:
    dec pool.numInbound
    nec_p2p_inbound_peers.dec()
  else:
    nec_p2p_outbound_peers.dec()
  rlpx_connected_peers.dec()

  # `supports` below needs the dispatcher, and a peer can be disconnected
  # before that is set up.
  if peer.dispatcher.isNil:
    return

  for observer in pool.observers.values:
    if not observer.onPeerDisconnected.isNil:
      if observer.protocols.len == 0 or peer.supports(observer.protocols):
        observer.onPeerDisconnected(peer)
