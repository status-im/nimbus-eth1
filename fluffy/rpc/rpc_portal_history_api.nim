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
  json_serialization/std/tables,
  stew/byteutils,
  ../network/wire/portal_protocol,
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export tables

# Portal Network JSON-RPC implementation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

ContentInfo.useDefaultSerializationIn JrpcConv
TraceContentLookupResult.useDefaultSerializationIn JrpcConv
TraceObject.useDefaultSerializationIn JrpcConv
NodeMetadata.useDefaultSerializationIn JrpcConv
TraceResponse.useDefaultSerializationIn JrpcConv

proc installPortalHistoryApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
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

  rpcServer.rpc("portal_historyGetContent") do(contentKey: string) -> ContentInfo:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise invalidKeyErr()
      maybeContent = p.getLocalContent(key, contentId)

    if maybeContent.isSome():
      return ContentInfo(content: maybeContent.get().to0xHex(), utpTransfer: false)

    let contentResult = (await p.contentLookup(key, contentId)).valueOr:
      raise contentNotFoundErr()

    return ContentInfo(
      content: contentResult.content.to0xHex(), utpTransfer: contentResult.utpTransfer
    )

  rpcServer.rpc("portal_historyTraceGetContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise invalidKeyErr()
      maybeContent = p.getLocalContent(key, contentId)

    if maybeContent.isSome():
      return TraceContentLookupResult(content: maybeContent, utpTransfer: false)

    let res = await p.traceContentLookup(key, contentId)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    if res.content.isSome():
      return res
    else:
      let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
      raise contentNotFoundErrWithTrace(data)

  rpcServer.rpc("portal_historyStore") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentValueBytes = hexToSeqByte(contentValue)
      contentId = p.toContentId(key).valueOr:
        raise invalidKeyErr()

    p.storeContent(key, contentId, contentValueBytes)

  rpcServer.rpc("portal_historyLocalContent") do(contentKey: string) -> string:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise invalidKeyErr()

      contentResult = p.dbGet(key, contentId).valueOr:
        raise contentNotFoundErr()

    return contentResult.to0xHex()

  rpcServer.rpc("portal_historyPutContent") do(
    contentKey: string, contentValue: string
  ) -> PutContentResult:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise invalidKeyErr()
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[key])

      # TODO: validate content
      storedLocally = p.storeContent(key, contentId, content)
      peerCount = await p.neighborhoodGossip(Opt.none(NodeId), contentKeys, @[content])

    PutContentResult(storedLocally: storedLocally, peerCount: peerCount)
