# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, math],
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  eth/p2p/discoveryv5/nodes_verification,
  ../network/wire/portal_protocol,
  ./rpc_types

export rpcserver

# Portal Network JSON-RPC impelentation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

type
  ContentInfo = object
    content: string
    utpTransfer: bool

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [CatchableError].} =

  rpcServer.rpc("portal_" & network & "NodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & network & "RoutingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & network & "AddEnr") do(enr: Record) -> bool:
    let node = newNode(enr).valueOr:
      raise newException(ValueError, "Failed creating Node from ENR")

    let addResult = p.addNode(node)
    p.routingTable.setJustSeen(node)
    return addResult == Added

  rpcServer.rpc("portal_" & network & "AddEnrs") do(enrs: seq[Record]) -> bool:
    # Note: unspecified RPC, but useful for our local testnet test
    for enr in enrs:
      let nodeRes = newNode(enr)
      if nodeRes.isOk():
        let node = nodeRes.get()
        discard p.addNode(node)
        p.routingTable.setJustSeen(node)

    return true

  rpcServer.rpc("portal_" & network & "GetEnr") do(nodeId: NodeId) -> Record:
    if p.localNode.id == nodeId:
      return p.localNode.record

    let node = p.getNode(nodeId)
    if node.isSome():
      return node.get().record
    else:
      raise newException(ValueError, "Record not in local routing table.")

  rpcServer.rpc("portal_" & network & "DeleteEnr") do(nodeId: NodeId) -> bool:
    # TODO: Adjust `removeNode` to accept NodeId as param and to return bool.
    let node = p.getNode(nodeId)
    if node.isSome():
      p.routingTable.removeNode(node.get())
      return true
    else:
      return false

  rpcServer.rpc("portal_" & network & "LookupEnr") do(nodeId: NodeId) -> Record:
    let lookup = await p.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("portal_" & network & "Ping") do(
      enr: Record) -> tuple[enrSeq: uint64, dataRadius: UInt256]:
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
          try: SSZ.decode(p.customPayload.asSeq(), CustomPayload)
          except MalformedSszError, SszSizeMismatchError:
            raiseAssert("Already verified")
      return (
        p.enrSeq,
        decodedPayload.dataRadius
      )

  rpcServer.rpc("portal_" & network & "FindNodes") do(
      enr: Record, distances: seq[uint16]) -> seq[Record]:
    let
      node = toNodeWithAddress(enr)
      nodes = await p.findNodes(node, distances)
    if nodes.isErr():
      raise newException(ValueError, $nodes.error)
    else:
      return nodes.get().map(proc(n: Node): Record = n.record)

  rpcServer.rpc("portal_" & network & "FindContent") do(
      enr: Record, contentKey: string) -> JsonNode:
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
        return %ContentInfo(
          content: foundContent.content.to0xHex(),
          utpTransfer: foundContent.utpTransfer
        )
      of Nodes:
        var rpcRes = newJObject()
        rpcRes["enrs"] = %foundContent.nodes.map(proc(n: Node): Record = n.record)
        return rpcRes

  rpcServer.rpc("portal_" & network & "Offer") do(
      enr: Record, contentKey: string, contentValue: string) -> string:
    let
      node = toNodeWithAddress(enr)
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKV = ContentKV(contentKey: ByteList.init(key), content: content)
      res = await p.offer(node, @[contentKV])

    if res.isOk():
      return SSZ.encode(res.get()).to0xHex()
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "RecursiveFindNodes") do(
      nodeId: NodeId) -> seq[Record]:
    let discovered = await p.lookup(nodeId)
    return discovered.map(proc(n: Node): Record = n.record)

  rpcServer.rpc("portal_" & network & "RecursiveFindContent") do(
      contentKey: string) -> ContentInfo:
    let
      key = ByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise newException(ValueError, "Invalid content key")

      contentResult = (await p.contentLookup(key, contentId)).valueOr:
        return ContentInfo(content: "0x", utpTransfer: false)

    return ContentInfo(
        content: contentResult.content.to0xHex(),
        utpTransfer: contentResult.utpTransfer
      )

  rpcServer.rpc("portal_historyTraceRecursiveFindContent") do(
      contentKey: string) -> TraceNodeInfo:

    let
      key = ByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise newException(ValueError, "Invalid content key")

      contentResult = (await p.traceContentLookup(key, contentId)).valueOr:
        return TraceNodeInfo(content: "0x")

    return TraceNodeInfo(
        content: contentResult.content.to0xHex(),
        trace: contentResult.trace
      )

  rpcServer.rpc("portal_" & network & "Store") do(
      contentKey: string, contentValue: string) -> bool:
    let key = ByteList.init(hexToSeqByte(contentKey))
    let contentId = p.toContentId(key)

    if contentId.isSome():
      p.storeContent(key, contentId.get(), hexToSeqByte(contentValue))
      return true
    else:
      raise newException(ValueError, "Invalid content key")

  rpcServer.rpc("portal_" & network & "LocalContent") do(
      contentKey: string) -> string:
    let
      key = ByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise newException(ValueError, "Invalid content key")

      contentResult = p.dbGet(key, contentId).valueOr:
        return "0x"

    return contentResult.to0xHex()

  rpcServer.rpc("portal_" & network & "Gossip") do(
      contentKey: string, contentValue: string) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ByteList.init(key)])
      numberOfPeers = await p.neighborhoodGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers

  rpcServer.rpc("portal_" & network & "RandomGossip") do(
      contentKey: string, contentValue: string) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ByteList.init(key)])
      numberOfPeers = await p.randomGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers
