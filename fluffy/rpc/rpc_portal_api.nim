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
  ../network/wire/portal_protocol,
  ../network/state/state_content,
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export rpcserver, tables

# Portal Network JSON-RPC impelentation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

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
proc installPortalApiHandlers*(
    rpcServer: RpcServer, p: PortalProtocol, network: static string
) =
  let
    invalidKeyErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")
    invalidValueErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content value")

  rpcServer.rpc("portal_" & network & "NodeInfo") do() -> NodeInfo:
    return p.routingTable.getNodeInfo()

  rpcServer.rpc("portal_" & network & "RoutingTableInfo") do() -> RoutingTableInfo:
    return getRoutingTableInfo(p.routingTable)

  rpcServer.rpc("portal_" & network & "AddEnr") do(enr: Record) -> bool:
    let node = Node.fromRecord(enr)
    let addResult = p.addNode(node)
    if addResult == Added:
      p.routingTable.setJustSeen(node)
    return addResult == Added

  rpcServer.rpc("portal_" & network & "AddEnrs") do(enrs: seq[Record]) -> bool:
    # Note: unspecified RPC, but useful for our local testnet test
    for enr in enrs:
      let node = Node.fromRecord(enr)
      if p.addNode(node) == Added:
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

  rpcServer.rpc("portal_" & network & "Ping") do(enr: Record) -> PingResult:
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

  rpcServer.rpc("portal_" & network & "FindNodes") do(
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

  rpcServer.rpc("portal_" & network & "FindContent") do(
    enr: Record, contentKey: string
  ) -> JsonString:
    let
      node = toNodeWithAddress(enr)
      foundContentResult =
        await p.findContent(node, ContentKeyByteList.init(hexToSeqByte(contentKey)))

    if foundContentResult.isErr():
      raise newException(ValueError, $foundContentResult.error)
    else:
      let foundContent = foundContentResult.get()
      case foundContent.kind
      of Content:
        let res = ContentInfo(
          content: foundContent.content.to0xHex(), utpTransfer: foundContent.utpTransfer
        )
        return JrpcConv.encode(res).JsonString
      of Nodes:
        let enrs = foundContent.nodes.map(
          proc(n: Node): Record =
            n.record
        )
        let jsonEnrs = JrpcConv.encode(enrs)
        return ("{\"enrs\":" & jsonEnrs & "}").JsonString

  rpcServer.rpc("portal_" & network & "Offer") do(
    enr: Record, contentKey: string, contentValue: string
  ) -> string:
    let
      node = toNodeWithAddress(enr)
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKV = ContentKV(contentKey: ContentKeyByteList.init(key), content: content)
      res = await p.offer(node, @[contentKV])

    if res.isOk():
      return SSZ.encode(res.get()).to0xHex()
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "RecursiveFindNodes") do(
    nodeId: NodeId
  ) -> seq[Record]:
    let discovered = await p.lookup(nodeId)
    return discovered.map(
      proc(n: Node): Record =
        n.record
    )

  rpcServer.rpc("portal_" & network & "RecursiveFindContent") do(
    contentKey: string
  ) -> ContentInfo:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = (await p.contentLookup(key, contentId)).valueOr:
        raise (ref ApplicationError)(code: -39001, msg: "Content not found")

    return ContentInfo(
      content: contentResult.content.to0xHex(), utpTransfer: contentResult.utpTransfer
    )

  rpcServer.rpc("portal_" & network & "TraceRecursiveFindContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      res = await p.traceContentLookup(key, contentId)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    if res.content.isSome():
      return res
    else:
      let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
      raise (ref ApplicationError)(code: -39001, msg: "Content not found", data: data)

  rpcServer.rpc("portal_" & network & "Store") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentValueBytes = hexToSeqByte(contentValue)

    let valueToStore =
      if network == "state":
        let decodedKey = ContentKey.decode(key).valueOr:
          raise invalidKeyErr

        case decodedKey.contentType
        of unused:
          raise invalidKeyErr
        of accountTrieNode:
          let offerValue = AccountTrieNodeOffer.decode(contentValueBytes).valueOr:
            raise invalidValueErr
          offerValue.toRetrievalValue.encode()
        of contractTrieNode:
          let offerValue = ContractTrieNodeOffer.decode(contentValueBytes).valueOr:
            raise invalidValueErr
          offerValue.toRetrievalValue.encode()
        of contractCode:
          let offerValue = ContractCodeOffer.decode(contentValueBytes).valueOr:
            raise invalidValueErr
          offerValue.toRetrievalValue.encode()
      else:
        contentValueBytes

    let contentId = p.toContentId(key)
    if contentId.isSome():
      p.storeContent(key, contentId.get(), valueToStore)
      return true
    else:
      raise invalidKeyErr

  rpcServer.rpc("portal_" & network & "LocalContent") do(contentKey: string) -> string:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = p.dbGet(key, contentId).valueOr:
        raise (ref ApplicationError)(code: -39001, msg: "Content not found")

    return contentResult.to0xHex()

  rpcServer.rpc("portal_" & network & "Gossip") do(
    contentKey: string, contentValue: string
  ) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ContentKeyByteList.init(key)])
      numberOfPeers =
        await p.neighborhoodGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers

  rpcServer.rpc("portal_" & network & "RandomGossip") do(
    contentKey: string, contentValue: string
  ) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ContentKeyByteList.init(key)])
      numberOfPeers = await p.randomGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers
