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
  std/macrocache,
  ./p2p_types

const
  protocolCounter = CacheCounter"protocolCounter"

let
  protocolManager = ProtocolManager[Peer, EthereumNode]()

#------------------------------------------------------------------------------
# Private functions
#------------------------------------------------------------------------------

func getProtocolIndex(): int {.compileTime.} =
  let protocolIndex = protocolCounter.value
  protocolCounter.inc
  protocolIndex

func getProtocol(index: int): auto {.gcsafe.} =
  {.gcsafe, noSideEffect.}:
    protocolManager.protocols[index]

func initPeerState[T](state: T, x: Peer) =
  discard

func initNetworkState[T](state: T, x: EthereumNode) =
  discard

func createPeerState[Peer, PeerState](peer: Peer): RootRef =
  when PeerState is void:
    RootRef(nil)
  else:
    var res = new PeerState
    mixin initPeerState
    initPeerState(res, peer)
    return cast[RootRef](res)

func createNetworkState[Network, NetworkState](network: Network): RootRef {.gcsafe.} =
  when NetworkState is void:
    RootRef(nil)
  else:
    var res = new NetworkState
    mixin initNetworkState
    initNetworkState(res, network)
    return cast[RootRef](res)

func initProtocol(
    name: string,
    version: uint64,
    peerInit: PeerStateInitializer,
    networkInit: NetworkStateInitializer,
): ProtocolInfo =
  ProtocolInfo(
    capability: Capability(name: name, version: version),
    messages: @[],
    peerStateInitializer: peerInit,
    networkStateInitializer: networkInit,
  )

#------------------------------------------------------------------------------
# Public functions
#------------------------------------------------------------------------------

# The variables above are immutable RTTI information. We need to tell
# Nim to not consider them GcSafe violations:
proc registerProtocol*(proto: ProtocolInfo) {.gcsafe.} =
  {.gcsafe.}:
    proto.index = protocolManager.len
    if proto.capability.name == "p2p":
      doAssert(proto.index == 0)
    protocolManager.protocols[proto.index] = proto
    inc protocolManager.len

template devp2pInfo*(): auto =
  getProtocol(0)

template defineProtocol*(PROTO: untyped,
                         version: static[int],
                         rlpxName: static[string],
                         PeerStateType: distinct type = void,
                         NetworkStateType: distinct type = void,
                         subProtocol: static[bool] = true) =
  type
    PROTO* = object

  const
    PROTOIndex = getProtocolIndex()

  static:
    when PROTOIndex >= MAX_PROTOCOLS:
      {.error: "Registered protocols exceeds MAX_PROTOCOLS".}

  template protocolInfo*(_: type PROTO): auto =
    getProtocol(PROTOIndex)

  template State*(_: type PROTO): type =
    PeerStateType

  template NetworkState*(_: type PROTO): type =
    NetworkStateType

  template protocolVersion*(_: type PROTO): int =
    version

  template isSubProtocol*(_: type PROTO): bool =
    subProtocol

  func initProtocol*(_: type PROTO): auto =
    initProtocol(rlpxName,
      version,
      createPeerState[Peer, PeerStateType],
      createNetworkState[EthereumNode, NetworkStateType])

  func state*(peer: Peer, _: type PROTO): PeerStateType =
    ## Returns the state object of a particular protocol for a
    ## particular connection.
    cast[PeerStateType](peer.peerStates[PROTO.protocolInfo.index])

  func networkState*(peer: Peer, _: type PROTO): NetworkStateType =
    ## Returns the network state object of a particular protocol for a
    ## particular connection.
    cast[NetworkStateType](peer.network.networkStates[PROTO.protocolInfo.index])

{.pop.}

