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
  chronos,
  eth/common/[base, keys],
  ./discoveryv4,
  ./rlpx/rlpxtransport,
  ./discoveryv4/[enode, kademlia],
  ./p2p_peers,
  ./peer_pool

export
  base.NetworkId, rlpxtransport, kademlia,
  p2p_peers

type
  Peer* = PeerRef[EthereumNode]
  Dispatcher* = DispatcherRef[Peer, EthereumNode]
  ProtocolInfo* = ProtocolInfoRef[Peer, EthereumNode]
  MessageInfo* = MessageInfoRef[Peer]
  PeerPool* = PeerPoolRef[EthereumNode]
  PeerObserver* = PeerObserverRef[EthereumNode]

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
    networkStates*: array[MAX_PROTOCOLS, RootRef] # e.g. WireRef
    listeningServer*: StreamServer

    rng*: ref HmacDrbgContext

proc toENode*(v: EthereumNode): ENode =
  ENode(pubkey: v.keys.pubkey, address: v.address)
