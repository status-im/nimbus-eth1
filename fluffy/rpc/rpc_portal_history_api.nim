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
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export tables

# Portal Network JSON-RPC implementation as per specification:
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

proc installPortalHistoryApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
  let
    invalidKeyErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")
    invalidValueErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content value")

  rpcServer.rpc("portal_historyFindContent") do(
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

  rpcServer.rpc("portal_historyOffer") do(
    enr: Record, contentItems: seq[ContentItem]
  ) -> string:
    let node = toNodeWithAddress(enr)

    var contentItemsToOffer: seq[ContentKV]
    for contentItem in contentItems:
      let
        contentKey = hexToSeqByte(contentItem[0])
        contentValue = hexToSeqByte(contentItem[1])
        contentKV = ContentKV(
          contentKey: ContentKeyByteList.init(contentKey), content: contentValue
        )
      contentItemsToOffer.add(contentKV)

    let offerResult = (await p.offer(node, contentItemsToOffer)).valueOr:
      raise newException(ValueError, $error)

    SSZ.encode(offerResult).to0xHex()

  rpcServer.rpc("portal_historyRecursiveFindContent") do(
    contentKey: string
  ) -> ContentInfo:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = (await p.contentLookup(key, contentId)).valueOr:
        raise (ref ApplicationError)(
          code: ContentNotFoundError.code, msg: ContentNotFoundError.msg
        )

    return ContentInfo(
      content: contentResult.content.to0xHex(), utpTransfer: contentResult.utpTransfer
    )

  rpcServer.rpc("portal_historyTraceRecursiveFindContent") do(
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
      raise (ref ApplicationError)(
        code: ContentNotFoundErrorWithTrace.code,
        msg: ContentNotFoundErrorWithTrace.msg,
        data: data,
      )

  rpcServer.rpc("portal_historyStore") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentValueBytes = hexToSeqByte(contentValue)
      contentId = p.toContentId(key)

    if contentId.isSome():
      p.storeContent(key, contentId.get(), contentValueBytes)
      return true
    else:
      raise invalidKeyErr

  rpcServer.rpc("portal_historyLocalContent") do(contentKey: string) -> string:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = p.dbGet(key, contentId).valueOr:
        raise (ref ApplicationError)(
          code: ContentNotFoundError.code, msg: ContentNotFoundError.msg
        )

    return contentResult.to0xHex()

  rpcServer.rpc("portal_historyGossip") do(
    contentKey: string, contentValue: string
  ) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ContentKeyByteList.init(key)])
      numberOfPeers =
        await p.neighborhoodGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers
