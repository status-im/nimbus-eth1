# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils, tables],
  nimcrypto, eth/common as eth_common, stint, json_rpc/server,
  eth/p2p, eth/p2p/enode,
  ../config, ./hexstrings

type
  NodePorts = object
    discovery: string
    listener : string

  NodeInfo = object
    id    : string # UInt256 hex
    name  : string
    enode : string # Enode string
    ip    : string # address string
    ports : NodePorts

proc setupCommonRpc*(node: EthereumNode, conf: NimbusConf, server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = conf.agentString

  server.rpc("web3_sha3") do(data: HexDataStr) -> string:
    var rawdata = nimcrypto.fromHex(data.string[2 .. ^1])
    result = "0x" & $keccak256.digest(rawdata)

  server.rpc("net_version") do() -> string:
    result = $conf.networkId

  server.rpc("net_listening") do() -> bool:
    let numPeers = node.peerPool.connectedNodes.len
    result = numPeers < conf.maxPeers

  server.rpc("net_peerCount") do() -> HexQuantityStr:
    let peerCount = uint node.peerPool.connectedNodes.len
    result = encodeQuantity(peerCount)

  server.rpc("net_nodeInfo") do() -> NodeInfo:
    let enode = toENode(node)
    let nodeId = toNodeId(node.keys.pubkey)
    result = NodeInfo(
      id: nodeId.toHex,
      name: conf.agentString,
      enode: $enode,
      ip: $enode.address.ip,
      ports: NodePorts(
        discovery: $enode.address.udpPort,
        listener: $enode.address.tcpPort
      )
    )
