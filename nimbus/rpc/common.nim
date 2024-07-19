# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common,
  stint,
  json_rpc/server,
  json_rpc/errors,
  eth/p2p,
  eth/p2p/enode,
  ../config,
  ../beacon/web3_eth_conv,
  web3/conversions

{.push raises: [].}

type
  NodePorts = object
    discovery: string
    listener: string

  NodeInfo = object
    id: string # UInt256 hex
    name: string
    enode: string # Enode string
    ip: string # address string
    ports: NodePorts

NodePorts.useDefaultSerializationIn JrpcConv
NodeInfo.useDefaultSerializationIn JrpcConv

proc setupCommonRpc*(node: EthereumNode, conf: NimbusConf, server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = conf.agentString

  server.rpc("web3_sha3") do(data: seq[byte]) -> Web3Hash:
    result = w3Hash(keccakHash(data))

  server.rpc("net_version") do() -> string:
    result = $conf.networkId

  server.rpc("net_listening") do() -> bool:
    let numPeers = node.numPeers
    result = numPeers < conf.maxPeers

  server.rpc("net_peerCount") do() -> Web3Quantity:
    let peerCount = uint node.numPeers
    result = w3Qty(peerCount)

  server.rpc("admin_nodeInfo") do() -> NodeInfo:
    let
      enode = toENode(node)
      nodeId = toNodeId(node.keys.pubkey)
      nodeInfo = NodeInfo(
        id: nodeId.toHex,
        name: conf.agentString,
        enode: $enode,
        ip: $enode.address.ip,
        ports:
          NodePorts(discovery: $enode.address.udpPort, listener: $enode.address.tcpPort),
      )

    return nodeInfo

  server.rpc("admin_addPeer") do(enode: string) -> bool:
    var res = ENode.fromString(enode)
    if res.isOk:
      asyncSpawn node.connectToNode(res.get())
      return true
    raise (ref InvalidRequest)(code: -32602, msg: "Invalid ENode")
