# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ./rpc_types

export rpc_types # tasty sandwich

type
  PongResponse* = object
    enrSeq: uint64
    recipientIP: string
    recipientPort: uint16

proc installDiscoveryApiHandlers*(rpcServer: RpcServer|RpcProxy,
    d: discv5_protocol.Protocol) =
  ## Discovery v5 JSON-RPC API such as defined here:
  ## https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

  rpcServer.rpc("discv5_nodeInfo") do() -> NodeInfo:
    return d.routingTable.getNodeInfo()

  rpcServer.rpc("discv5_updateNodeInfo") do(
      kvPairs: seq[(string, string)]) -> NodeInfo:
    # TODO: Not according to spec, as spec parameters are weird.
    # It is currently as in
    # https://ddht.readthedocs.io/en/latest/jsonrpc.html#discv5-updatenodeinfo
    let enrFields = kvPairs.map(
      proc(n: (string, string)): (string, seq[byte]) {.raises: [ValueError].} =
        (n[0], hexToSeqByte(n[1]))
      )
    let updated = d.updateRecord(enrFields)
    if updated.isErr():
      raise newException(ValueError, $updated.error)

    return d.routingTable.getNodeInfo()

  rpcServer.rpc("discv5_routingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(d.routingTable)

  rpcServer.rpc("discv5_addEnr") do(enr: Record) -> bool:
    let nodeRes = newNode(enr)
    if nodeRes.isOk():
      let node = nodeRes.get()
      let res = d.addNode(node)
      d.routingTable.setJustSeen(node)
      return res
    else:
      raise newException(ValueError, "Failed creating Node from ENR")

  rpcServer.rpc("discv5_addEnrs") do(enrs: seq[Record]) -> bool:
    # Note: unspecified RPC, but useful for our local testnet test
    # TODO: We could also adjust the API of addNode & newNode to accept a seen
    # parameter, but perhaps only if that makes sense on other locations in
    # discv5/portal that are not testing/debug related.
    for enr in enrs:
      let nodeRes = newNode(enr)
      if nodeRes.isOk():
        let node = nodeRes.get()
        discard d.addNode(node)
        d.routingTable.setJustSeen(node)

    return true

  rpcServer.rpc("discv5_getEnr") do(nodeId: NodeId) -> Record:
    let node = d.getNode(nodeId)
    if node.isSome():
      return node.get().record
    else:
      raise newException(ValueError, "Record not in local routing table.")

  rpcServer.rpc("discv5_deleteEnr") do(nodeId: NodeId) -> bool:
    # TODO: Adjust `removeNode` to accept NodeId as param and to return bool.
    let node = d.getNode(nodeId)
    if node.isSome():
      d.routingTable.removeNode(node.get())
      return true
    else:
      raise newException(ValueError, "Record not in local routing table.")

  rpcServer.rpc("discv5_lookupEnr") do(
      nodeId: NodeId) -> Record:
    # TODO: Not according to spec, missing optional enrSeq
    # Can add `enrSeq: Option[uint64]` as parameter but Option appears to be
    # not implemented as an option parameter in nim-json-rpc?
    let lookup = await d.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("discv5_ping") do(enr: Record) -> PongResponse:
    let
      node = toNodeWithAddress(enr)
      pong = await d.ping(node)

    if pong.isErr():
      raise newException(ValueError, $pong.error)
    else:
      let p = pong.get()
      return PongResponse(
        enrSeq: p.enrSeq,
        recipientIP: $p.ip,
        recipientPort: p.port
      )

  rpcServer.rpc("discv5_findNode") do(
      enr: Record, distances: seq[uint16]) -> seq[Record]:
    let
      node = toNodeWithAddress(enr)
      nodes = await d.findNode(node, distances)
    if nodes.isErr():
      raise newException(ValueError, $nodes.error)
    else:
      return nodes.get().map(proc(n: Node): Record = n.record)

  rpcServer.rpc("discv5_talkReq") do(
      enr: Record, protocol, payload: string) -> string:
    let
      node = toNodeWithAddress(enr)
      talkresp = await d.talkReq(
        node, hexToSeqByte(protocol), hexToSeqByte(payload))
    if talkresp.isErr():
      raise newException(ValueError, $talkresp.error)
    else:
      return talkresp.get().toHex()

  rpcServer.rpc("discv5_recursiveFindNodes") do(nodeId: NodeId) -> seq[Record]:
    let discovered = await d.lookup(nodeId)
    return discovered.map(proc(n: Node): Record = n.record)
