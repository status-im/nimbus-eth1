# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, json],
  json_rpc/rpcserver,
  json_serialization/std/tables,
  stew/byteutils,
  ../network/wire/[portal_protocol, portal_protocol_config],
  ../network/state/state_content,
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export rpcserver, tables, portal_protocol_config

# Portal Network JSON-RPC impelentation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

const
  ContentNotFoundError = (code: -39001, msg: "Content not found")
  ContentNotFoundErrorWithTrace = (code: -39002, msg: "Content not found")

type ContentInfo = object
  content: string
  utpTransfer: bool

ContentInfo.useDefaultSerializationIn JrpcConv
TraceContentLookupResult.useDefaultSerializationIn JrpcConv
TraceObject.useDefaultSerializationIn JrpcConv
NodeMetadata.useDefaultSerializationIn JrpcConv
TraceResponse.useDefaultSerializationIn JrpcConv

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalCommonApiHandlers*(
    rpcServer: RpcServer, p: PortalProtocol, network: static PortalSubnetwork
) =
  const networkStr = network.symbolName()

  let
    invalidKeyErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")
    invalidValueErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content value")

  rpcServer.rpc("portal_" & networkStr & "NodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & networkStr & "RoutingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & networkStr & "AddEnr") do(enr: Record) -> bool:
    let node = Node.fromRecord(enr)
    let addResult = p.addNode(node)
    if addResult == Added:
      p.routingTable.setJustSeen(node)
    return addResult == Added

  rpcServer.rpc("portal_" & networkStr & "AddEnrs") do(enrs: seq[Record]) -> bool:
    # Note: unspecified RPC, but useful for our local testnet test
    for enr in enrs:
      let node = Node.fromRecord(enr)
      if p.addNode(node) == Added:
        p.routingTable.setJustSeen(node)

    return true

  rpcServer.rpc("portal_" & networkStr & "GetEnr") do(nodeId: NodeId) -> Record:
    if p.localNode.id == nodeId:
      return p.localNode.record

    let node = p.getNode(nodeId)
    if node.isSome():
      return node.get().record
    else:
      raise newException(ValueError, "Record not in local routing table.")

  rpcServer.rpc("portal_" & networkStr & "DeleteEnr") do(nodeId: NodeId) -> bool:
    # TODO: Adjust `removeNode` to accept NodeId as param and to return bool.
    let node = p.getNode(nodeId)
    if node.isSome():
      p.routingTable.removeNode(node.get())
      return true
    else:
      return false

  rpcServer.rpc("portal_" & networkStr & "LookupEnr") do(nodeId: NodeId) -> Record:
    let lookup = await p.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("portal_" & networkStr & "Ping") do(enr: Record) -> PingResult:
    let
      node = toNodeWithAddress(enr)
      pong = await p.ping(node)

    if pong.isErr():
      raise newException(ValueError, $pong.error)
    else:
      let
        p = pong.get()
        # Note: the SSZ.decode cannot fail here as it has already been verified
        # in the ping call.
        decodedPayload =
          try:
            SSZ.decode(p.customPayload.asSeq(), CustomPayload)
          except MalformedSszError, SszSizeMismatchError:
            raiseAssert("Already verified")
      return (p.enrSeq, decodedPayload.dataRadius)

  rpcServer.rpc("portal_" & networkStr & "FindNodes") do(
    enr: Record, distances: seq[uint16]
  ) -> seq[Record]:
    let
      node = toNodeWithAddress(enr)
      nodes = await p.findNodes(node, distances)
    if nodes.isErr():
      raise newException(ValueError, $nodes.error)
    else:
      return nodes.get().map(
          proc(n: Node): Record =
            n.record
        )

  rpcServer.rpc("portal_" & networkStr & "RecursiveFindNodes") do(
    nodeId: NodeId
  ) -> seq[Record]:
    let discovered = await p.lookup(nodeId)
    return discovered.map(
      proc(n: Node): Record =
        n.record
    )
