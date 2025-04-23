# fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, json],
  json_rpc/rpcserver,
  stew/byteutils,
  results,
  ../network/wire/[portal_protocol, portal_protocol_config, ping_extensions],
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export portal_protocol_config

# Portal Network JSON-RPC implementation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

proc installPortalCommonApiHandlers*(
    rpcServer: RpcServer, p: PortalProtocol, network: static PortalSubnetwork
) =
  const networkStr = network.symbolName()

  rpcServer.rpc("portal_" & networkStr & "NodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & networkStr & "RoutingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & networkStr & "AddEnr") do(enr: Record) -> bool:
    let node = Node.fromRecord(enr)
    if p.addNode(node) == Added:
      p.routingTable.setJustSeen(node)
      true
    else:
      false

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

  rpcServer.rpc("portal_" & networkStr & "Ping") do(
    enr: Record, payloadType: Opt[uint16], payload: Opt[UnknownPayload]
  ) -> PingResult:
    if payloadType.isSome() and payloadType.get() != CapabilitiesType:
      # We only support sending the default CapabilitiesPayload for now.
      # This is fine because according to the spec clients are only required
      # to support the standard extensions.
      raise payloadTypeNotSupportedError()

    if payload.isSome():
      # We don't support passing in a custom payload. In order to implement
      # this we use the empty UnknownPayload type which is defined in the spec
      # as a json object with no required fields. Just using it here to indicate
      # if an object was supplied or not and then throw the correct error if so.
      raise userSpecifiedPayloadBlockedByClientError()

    let
      node = toNodeWithAddress(enr)
      pong = (await p.ping(node)).valueOr:
        raise newException(ValueError, $error)

    let
      (enrSeq, payloadType, capabilitiesPayload) = pong
      clientInfo = capabilitiesPayload.client_info.asSeq()
      payload = (
        string.fromBytes(clientInfo),
        capabilitiesPayload.data_radius,
        capabilitiesPayload.capabilities.asSeq(),
      )

    return PingResult(enrSeq: enrSeq, payloadType: payloadType, payload: payload)

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
