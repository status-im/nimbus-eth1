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
  eth/p2p/discoveryv5/nodes_verification,
  ../network/wire/portal_protocol,
  ./rpc_types

export rpcserver

# Portal Network JSON-RPC impelentation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

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
      raise newException(ValueError, "Record not in local routing table.")

  rpcServer.rpc("portal_" & network & "LookupEnr") do(nodeId: NodeId) -> Record:
    # TODO: Not fully according to spec, missing optional enrSeq
    # Can add `enrSeq: Option[uint64]` as parameter but Option appears to be
    # not implemented as an optional parameter in nim-json-rpc?
    let lookup = await p.resolve(nodeId)
    if lookup.isSome():
      return lookup.get().record
    else:
      raise newException(ValueError, "Record not found in DHT lookup.")

  rpcServer.rpc("portal_" & network & "Ping") do(
      enr: Record) -> tuple[enrSeq: uint64, customPayload: string]:
    # TODO: Not fully according to spec:
    # - missing optional dataRadius
    # - customPayload instead of dataRadius returned
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
  rpcServer.rpc("portal_" & network & "FindContent") do(
      enr: Record, contentKey: string) -> tuple[
        connectionId: Option[string],
        content: Option[string],
        enrs: Option[seq[Record]]]:
    let
      node = toNodeWithAddress(enr)
      res = await p.findContentImpl(
        node, ByteList.init(hexToSeqByte(contentKey)))

    if res.isErr():
      raise newException(ValueError, $res.error)

    let contentMessage = res.get()
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

  rpcServer.rpc("portal_" & network & "FindContentFull") do(
      enr: Record, contentKey: string) -> tuple[
        content: Option[string], enrs: Option[seq[Record]]]:
    # Note: unspecified RPC, but useful as we can get content from uTP also
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
      enr: Record, contentKey: string, contentValue: string) -> string:
    let
      node = toNodeWithAddress(enr)
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentInfo = ContentInfo(contentKey: ByteList.init(key), content: content)
      res = await p.offer(node, @[contentInfo])

    if res.isOk():
      return "0x" & SSZ.encode(res.get()).toHex()
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "RecursiveFindNodes") do(
      nodeId: NodeId) -> seq[Record]:
    let discovered = await p.lookup(nodeId)
    return discovered.map(proc(n: Node): Record = n.record)

  rpcServer.rpc("portal_" & network & "RecursiveFindContent") do(
      contentKey: string) -> string:
    let
      key = ByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise newException(ValueError, "Invalid content key")

      contentResult = (await p.contentLookup(key, contentId)).valueOr:
        raise newException(ValueError, "Content not found")

    return contentResult.content.toHex()

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

    let contentResult = p.dbGet(key, contentId)
    if contentResult.isOk():
      return contentResult.get().toHex()
    else:
      return "0x0"

  rpcServer.rpc("portal_" & network & "Gossip") do(
      contentKey: string, contentValue: string) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ByteList.init(key)])
      numberOfPeers = await p.neighborhoodGossip(contentKeys, @[content])

    return numberOfPeers
