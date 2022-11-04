# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  eth/p2p/discoveryv5/nodes_verification,
  ../network/wire/portal_protocol,
  ./rpc_types

export rpcserver

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [Defect, CatchableError].} =
  ## Portal routing table and portal wire json-rpc API is not yet defined but
  ## will look something similar as what exists here now:
  ## https://github.com/ethereum/portal-network-specs/pull/88

  rpcServer.rpc("portal_" & network & "NodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & network & "RoutingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & network & "LookupEnr") do(nodeId: NodeId) -> Record:
    let lookup = await p.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("portal_" & network & "AddEnrs") do(enrs: seq[Record]) -> bool:
    for enr in enrs:
      let nodeRes = newNode(enr)
      if nodeRes.isOk():
        let node = nodeRes.get()
        discard p.addNode(node)
        p.routingTable.setJustSeen(node)

    return true

  rpcServer.rpc("portal_" & network & "Ping") do(
      enr: Record) -> tuple[seqNum: uint64, customPayload: string]:
    let
      node = toNodeWithAddress(enr)
      pong = await p.ping(node)

    if pong.isErr():
      raise newException(ValueError, $pong.error)
    else:
      let p = pong.get()
      return (p.enrSeq, p.customPayload.asSeq().toHex())

  rpcServer.rpc("portal_" & network & "FindNodes") do(
      enr: Record, distances: seq[uint16]) -> seq[Record]:
    let
      node = toNodeWithAddress(enr)
      nodes = await p.findNodes(node, distances)
    if nodes.isErr():
      raise newException(ValueError, $nodes.error)
    else:
      return nodes.get().map(proc(n: Node): Record = n.record)

  # TODO: This returns null values for the `none`s. Not sure what it should be
  # according to spec, no k:v pair at all?
  # Note: `*_findContentRaw` is actually `*_findContent` call according to
  # WIP Portal JSON-RPC API specification. Not sure about the best naming here.
  rpcServer.rpc("portal_" & network & "FindContentRaw") do(
      enr: Record, contentKey: string) -> tuple[
        connectionId: Option[string],
        content: Option[string],
        enrs: Option[seq[Record]]]:
    let
      node = toNodeWithAddress(enr)
      content = await p.findContentImpl(
        node, ByteList.init(hexToSeqByte(contentKey)))

    if content.isErr():
      raise newException(ValueError, $content.error)
    else:
      let contentMessage = content.get()
      case contentMessage.contentMessageType:
      of connectionIdType:
        return (
          some("0x" & contentMessage.connectionId.toHex()),
          none(string),
          none(seq[Record]))
      of contentType:
        return (
          none(string),
          some("0x" & contentMessage.content.asSeq().toHex()),
          none(seq[Record]))
      of enrsType:
        let records = recordsFromBytes(contentMessage.enrs)
        if records.isErr():
          raise newException(ValueError, $records.error)
        else:
          return (
            none(string),
            none(string),
            # Note: Could also pass not verified nodes
            some(verifyNodesRecords(
              records.get(), node, enrsResultLimit).map(
                proc(n: Node): Record = n.record)))

  rpcServer.rpc("portal_" & network & "FindContent") do(
      enr: Record, contentKey: string) -> tuple[
        content: Option[string], enrs: Option[seq[Record]]]:
    let
      node = toNodeWithAddress(enr)
      foundContentResult = await p.findContent(
        node, ByteList.init(hexToSeqByte(contentKey)))

    if foundContentResult.isErr():
      raise newException(ValueError, $foundContentResult.error)
    else:
      let foundContent = foundContentResult.get()
      case foundContent.kind:
      of Content:
        return (
          some("0x" & foundContent.content.toHex()),
          none(seq[Record]))
      of Nodes:
        return (
          none(string),
          some(foundContent.nodes.map(proc(n: Node): Record = n.record)))

  rpcServer.rpc("portal_" & network & "Offer") do(
      contentKey: string, content: string) -> int:
    let
      ck = hexToSeqByte(contentKey)
      ct = hexToSeqByte(content)
      contentKeys = ContentKeysList(@[ByteList.init(ck)])
      numberOfPeers = await p.neighborhoodGossip(contentKeys, @[ct])

    return numberOfPeers

  rpcServer.rpc("portal_" & network & "RecursiveFindNodes") do() -> seq[Record]:
    let discovered = await p.queryRandom()
    return discovered.map(proc(n: Node): Record = n.record)
