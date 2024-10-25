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
  ../network/state/[state_content, state_validation],
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

proc installPortalStateApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
  rpcServer.rpc("portal_stateFindContent") do(
    enr: Record, contentKey: string
  ) -> JsonString:
    let
      node = toNodeWithAddress(enr)
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, _) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      foundContent = (await p.findContent(node, keyBytes)).valueOr:
        raise newException(ValueError, $error)

    case foundContent.kind
    of Content:
      let contentValue = foundContent.content
      validateRetrieval(key, contentValue).isOkOr:
        raise invalidValueErr()

      let res = ContentInfo(
        content: contentValue.to0xHex(), utpTransfer: foundContent.utpTransfer
      )
      JrpcConv.encode(res).JsonString
    of Nodes:
      let enrs = foundContent.nodes.map(
        proc(n: Node): Record =
          n.record
      )
      let jsonEnrs = JrpcConv.encode(enrs)
      ("{\"enrs\":" & jsonEnrs & "}").JsonString

  rpcServer.rpc("portal_stateOffer") do(
    enr: Record, contentItems: seq[ContentItem]
  ) -> string:
    let node = toNodeWithAddress(enr)

    var contentItemsToOffer: seq[ContentKV]
    for contentItem in contentItems:
      let
        keyBytes = ContentKeyByteList.init(hexToSeqByte(contentItem[0]))
        (key, _) = validateGetContentKey(keyBytes).valueOr:
          raise invalidKeyErr()
        contentBytes = hexToSeqByte(contentItem[1])
        contentKV = ContentKV(contentKey: keyBytes, content: contentBytes)

      discard validateOfferGetRetrieval(key, contentBytes).valueOr:
        raise invalidValueErr()
      contentItemsToOffer.add(contentKV)

    let offerResult = (await p.offer(node, contentItemsToOffer)).valueOr:
      raise newException(ValueError, $error)

    SSZ.encode(offerResult).to0xHex()

  rpcServer.rpc("portal_stateGetContent") do(contentKey: string) -> ContentInfo:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      maybeContent = p.getLocalContent(keyBytes, contentId)
    if maybeContent.isSome():
      return ContentInfo(content: maybeContent.get().to0xHex(), utpTransfer: false)

    let
      foundContent = (await p.contentLookup(keyBytes, contentId)).valueOr:
        raise contentNotFoundErr()
      contentValue = foundContent.content

    validateRetrieval(key, contentValue).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, contentValue, cacheContent = true)

    ContentInfo(content: contentValue.to0xHex(), utpTransfer: foundContent.utpTransfer)

  rpcServer.rpc("portal_stateTraceGetContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      maybeContent = p.getLocalContent(keyBytes, contentId)
    if maybeContent.isSome():
      return TraceContentLookupResult(content: maybeContent, utpTransfer: false)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    let
      res = await p.traceContentLookup(keyBytes, contentId)
      contentValue = res.content.valueOr:
        let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
        raise contentNotFoundErrWithTrace(data)

    validateRetrieval(key, contentValue).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, contentValue, cacheContent = true)

    res

  rpcServer.rpc("portal_stateStore") do(contentKey: string, content: string) -> bool:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      contentBytes = hexToSeqByte(content)
      contentValue = validateOfferGetRetrieval(key, contentBytes).valueOr:
        raise invalidValueErr()

    p.storeContent(keyBytes, contentId, contentValue)

  rpcServer.rpc("portal_stateLocalContent") do(contentKey: string) -> string:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (_, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()

      contentResult = p.getLocalContent(keyBytes, contentId).valueOr:
        raise contentNotFoundErr()

    contentResult.to0xHex()

  rpcServer.rpc("portal_stateGossip") do(contentKey: string, content: string) -> int:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      contentBytes = hexToSeqByte(content)
      contentValue = validateOfferGetRetrieval(key, contentBytes).valueOr:
        raise invalidValueErr()

    p.storeContent(keyBytes, contentId, contentValue)

    await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[keyBytes]), @[contentBytes]
    )
