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
      foundContentResult = (await p.findContent(node, keyBytes)).valueOr:
        raise newException(ValueError, $error)

    case foundContentResult.kind
    of Content:
      let valueBytes = foundContentResult.content
      validateRetrieval(key, valueBytes).isOkOr:
        raise invalidValueErr()

      let res = ContentInfo(
        content: valueBytes.to0xHex(), utpTransfer: foundContentResult.utpTransfer
      )
      JrpcConv.encode(res).JsonString
    of Nodes:
      let enrs = foundContentResult.nodes.map(
        proc(n: Node): Record =
          n.record
      )
      let jsonEnrs = JrpcConv.encode(enrs)
      ("{\"enrs\":" & jsonEnrs & "}").JsonString

  rpcServer.rpc("portal_stateOffer") do(
    enr: Record, contentItems: seq[ContentItem]
  ) -> string:
    let node = toNodeWithAddress(enr)

    var contentOffers: seq[ContentKV]
    for contentItem in contentItems:
      let
        keyBytes = ContentKeyByteList.init(hexToSeqByte(contentItem[0]))
        (key, _) = validateGetContentKey(keyBytes).valueOr:
          raise invalidKeyErr()
        offerValueBytes = hexToSeqByte(contentItem[1])

      discard validateOfferGetRetrieval(key, offerValueBytes).valueOr:
        raise invalidValueErr()
      contentOffers.add(ContentKV(contentKey: keyBytes, content: offerValueBytes))

    let offerResult = (await p.offer(node, contentOffers)).valueOr:
      raise newException(ValueError, $error)

    SSZ.encode(offerResult).to0xHex()

  rpcServer.rpc("portal_stateGetContent") do(contentKey: string) -> ContentInfo:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      maybeValueBytes = p.getLocalContent(keyBytes, contentId)
    if maybeValueBytes.isSome():
      return ContentInfo(content: maybeValueBytes.get().to0xHex(), utpTransfer: false)

    let
      contentLookupResult = (await p.contentLookup(keyBytes, contentId)).valueOr:
        raise contentNotFoundErr()
      valueBytes = contentLookupResult.content

    validateRetrieval(key, valueBytes).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, valueBytes, cacheContent = true)

    ContentInfo(
      content: valueBytes.to0xHex(), utpTransfer: contentLookupResult.utpTransfer
    )

  rpcServer.rpc("portal_stateTraceGetContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      maybeValueBytes = p.getLocalContent(keyBytes, contentId)
    if maybeValueBytes.isSome():
      return TraceContentLookupResult(content: maybeValueBytes, utpTransfer: false)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    let
      res = await p.traceContentLookup(keyBytes, contentId)
      valueBytes = res.content.valueOr:
        let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
        raise contentNotFoundErrWithTrace(data)

    validateRetrieval(key, valueBytes).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, valueBytes, cacheContent = true)

    res

  rpcServer.rpc("portal_stateStore") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      offerValueBytes = hexToSeqByte(contentValue)
      valueBytes = validateOfferGetRetrieval(key, offerValueBytes).valueOr:
        raise invalidValueErr()

    p.storeContent(keyBytes, contentId, valueBytes)

  rpcServer.rpc("portal_stateLocalContent") do(contentKey: string) -> string:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (_, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()

      valueBytes = p.getLocalContent(keyBytes, contentId).valueOr:
        raise contentNotFoundErr()

    valueBytes.to0xHex()

  rpcServer.rpc("portal_statePutContent") do(
    contentKey: string, contentValue: string
  ) -> PutContentResult:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      (key, contentId) = validateGetContentKey(keyBytes).valueOr:
        raise invalidKeyErr()
      offerValueBytes = hexToSeqByte(contentValue)
      valueBytes = validateOfferGetRetrieval(key, offerValueBytes).valueOr:
        raise invalidValueErr()

      storedLocally = p.storeContent(keyBytes, contentId, valueBytes)
      peerCount = await p.neighborhoodGossip(
        Opt.none(NodeId), ContentKeysList(@[keyBytes]), @[offerValueBytes]
      )

    PutContentResult(storedLocally: storedLocally, peerCount: peerCount)
