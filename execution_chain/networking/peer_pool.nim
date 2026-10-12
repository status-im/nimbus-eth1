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
  std/[tables, sets],
  eth/common/base,
  ./p2p_metrics,
  ./[p2p_node, p2p_peers]

export sets, tables, base, p2p_node

type
  # Usually Network generic param is instantiated with EthereumNode
  PeerPoolRef*[Network] = ref object
    maxPeers*: int
      ## Hard limit on the number of connected peers, incoming and outgoing
      ## alike - see `isFull`
    dialTarget*: int
      ## Number of peers up to which we actively dial out. This is deliberately
      ## lower than `maxPeers` so that the dialer cannot fill every slot and
      ## leave the node unreachable for incoming connections.
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

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

func isFull*(p: PeerPoolRef): bool =
  ## `true` when the pool holds `maxPeers` peers and no further connection,
  ## incoming or outgoing, may be established.
  p.connectedNodes.len >= p.maxPeers

func newPeerPool*[Network](maxPeers = defaultMaxPeers): PeerPoolRef[Network] =
  let limit = max(1, maxPeers)
  PeerPoolRef[Network](
    maxPeers: limit,
    dialTarget: max(1, limit - limit div inboundSlotDivisor),
    connectedNodes: initTable[Node, PeerRef[Network]](),
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
