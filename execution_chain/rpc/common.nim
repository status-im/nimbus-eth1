# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  # Standard library imports are prefixed with `std/`
  std/[json, sequtils],
  stint, json_rpc/errors,
  chronos,
  ../networking/[p2p, discoveryv4/enode, peer_pool, p2p_types],
  ../config,
  ../beacon/web3_eth_conv,
  ../nimbus_desc,
  web3/conversions

from json_rpc/server import RpcServer, rpc

{.push raises: [].}

type
  NodePorts = object
    discovery*: int # TODO: Serialize `Port` into number
    listener* : int # using custom serializer

  NodeInfo* = object
    id*    : string # UInt256 hex
    name*  : string
    enode* : string # Enode string
    ip*    : string # address string
    ports* : NodePorts

  PeerNetworkInfo* = object
    inbound*: bool         # Whether connection was initiated by remote peer
    localAddress*: string  # Local endpoint
    remoteAddress*: string # Remote endpoint
    `static`*: bool        # Whether peer is static
    trusted*: bool         # Whether peer is trusted

  PeerInfo* = object
    caps*: seq[string]     # Protocol capabilities
    enode*: string         # ENode string
    id*: string            # Node ID hex
    name*: string          # Client ID
    network*: PeerNetworkInfo
    protocols*: JsonNode   # Protocol-specific data

NodePorts.useDefaultSerializationIn JrpcConv
NodeInfo.useDefaultSerializationIn JrpcConv
PeerNetworkInfo.useDefaultSerializationIn JrpcConv
PeerInfo.useDefaultSerializationIn JrpcConv

proc setupCommonRpc*(node: EthereumNode, conf: NimbusConf, server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = conf.agentString

  server.rpc("web3_sha3") do(data: seq[byte]) -> Hash32:
    result = keccak256(data)

  server.rpc("net_version") do() -> string:
    result = $conf.networkId

  server.rpc("net_listening") do() -> bool:
    let numPeers = node.numPeers
    result = numPeers < conf.maxPeers

  server.rpc("net_peerCount") do() -> Quantity:
    let peerCount = uint node.numPeers
    result = w3Qty(peerCount)

proc setupAdminRpc*(nimbus: NimbusNode, conf: NimbusConf, server: RpcServer) =
  let node = nimbus.ethNode

  server.rpc("admin_nodeInfo") do() -> NodeInfo:
    let
      enode = toENode(node)
      nodeId = toNodeId(node.keys.pubkey)
      nodeInfo = NodeInfo(
        id: nodeId.toHex,
        name: conf.agentString,
        enode: $enode,
        ip: $enode.address.ip,
        ports: NodePorts(
          discovery: int(enode.address.udpPort),
          listener: int(enode.address.tcpPort)
        )
      )

    return nodeInfo

  server.rpc("admin_addPeer") do(enode: string) -> bool:
    var res = ENode.fromString(enode)
    if res.isOk:
      asyncSpawn node.connectToNode(res.get())
      return true
    # Weird it is, but when addPeer fails, the calee expect
    # invalid params `-32602`(kurtosis test)
    raise (ref InvalidRequest)(code: -32602, msg: "Invalid ENode")

  server.rpc("admin_peers") do() -> seq[PeerInfo]:
    var peers: seq[PeerInfo]
    for peer in node.peerPool.peers:
      if peer.connectionState == Connected:
        let
          nodeId = peer.remote.id
          clientId = peer.clientId
          enode = $peer.remote.node
          remoteIp = $peer.remote.node.address.ip
          remoteTcpPort = $peer.remote.node.address.tcpPort
          localEnode = toENode(node)
          localIp = $localEnode.address.ip
          localTcpPort = $localEnode.address.tcpPort
          caps = node.capabilities.mapIt(it.name & "/" & $it.version)

        # Create protocols object with version info
        var protocolsObj = newJObject()
        for capability in node.capabilities:
          protocolsObj[capability.name] = %*{"version": capability.version}

        let peerInfo = PeerInfo(
          caps: caps,
          enode: enode,
          id: nodeId.toHex,
          name: clientId,
          network: PeerNetworkInfo(
            inbound: peer.inbound,
            localAddress: localIp & ":" & localTcpPort,
            remoteAddress: remoteIp & ":" & remoteTcpPort,
            `static`: false,  # TODO: implement static peer tracking
            trusted: false # TODO: implement trusted peer tracking
          ),
          protocols: protocolsObj
        )
        peers.add(peerInfo)

    return peers

  server.rpc("admin_quit") do() -> string:
    {.gcsafe.}:
      nimbus.state = NimbusState.Stopping
    result = "EXITING"
