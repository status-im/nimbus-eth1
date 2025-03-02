# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

let protocolManager = ProtocolManager()

# The variables above are immutable RTTI information. We need to tell
# Nim to not consider them GcSafe violations:
proc registerProtocol*(proto: ProtocolInfo) {.gcsafe.} =
  {.gcsafe.}:
    proto.index = protocolManager.protocols.len
    if proto.capability.name == "p2p":
      doAssert(proto.index == 0)
    protocolManager.protocols.add proto

proc protocolCount*(): int {.gcsafe.} =
  {.gcsafe.}:
    protocolManager.protocols.len

proc getProtocol*(index: int): ProtocolInfo {.gcsafe.} =
  {.gcsafe.}:
    protocolManager.protocols[index]

iterator protocols*(): ProtocolInfo {.gcsafe.} =
  {.gcsafe.}:
    for x in protocolManager.protocols:
      yield x

template getProtocol*(Protocol: type): ProtocolInfo =
  getProtocol(Protocol.index)

template devp2pInfo*(): ProtocolInfo =
  getProtocol(0)

proc getState*(peer: Peer, proto: ProtocolInfo): RootRef =
  peer.protocolStates[proto.index]

template state*(peer: Peer, Protocol: type): untyped =
  ## Returns the state object of a particular protocol for a
  ## particular connection.
  mixin State
  bind getState
  cast[Protocol.State](getState(peer, Protocol.protocolInfo))

proc getNetworkState*(node: EthereumNode, proto: ProtocolInfo): RootRef =
  node.protocolStates[proto.index]

template protocolState*(node: EthereumNode, Protocol: type): untyped =
  mixin NetworkState
  bind getNetworkState
  cast[Protocol.NetworkState](getNetworkState(node, Protocol.protocolInfo))

template networkState*(connection: Peer, Protocol: type): untyped =
  ## Returns the network state object of a particular protocol for a
  ## particular connection.
  protocolState(connection.network, Protocol)

proc initProtocolState*[T](state: T, x: Peer|EthereumNode)
    {.gcsafe, raises: [].} =
  discard

proc initProtocolStates(peer: Peer, protocols: openArray[ProtocolInfo])
    {.raises: [].} =
  # Initialize all the active protocol states
  newSeq(peer.protocolStates, protocolCount())
  for protocol in protocols:
    let peerStateInit = protocol.peerStateInitializer
    if peerStateInit != nil:
      peer.protocolStates[protocol.index] = peerStateInit(peer)

{.pop.}

