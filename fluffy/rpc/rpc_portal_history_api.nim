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
  ../network/history/history_network,
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

proc installPortalHistoryApiHandlers*(rpcServer: RpcServer, n: HistoryNetwork) =
  template p(): PortalProtocol =
    n.portalProtocol

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
        JrpcConv.encode(res).JsonString
      of Nodes:
        let enrs = foundContent.nodes.map(
          proc(n: Node): Record =
            n.record
        )
        let jsonEnrs = JrpcConv.encode(enrs)
        ("{\"enrs\":" & jsonEnrs & "}").JsonString

  rpcServer.rpc("portal_historyOffer") do(
    enr: Record, contentItems: seq[ContentItem]
  ) -> string:
    let node = toNodeWithAddress(enr)

    var contentOffers: seq[ContentKV]
    for contentItem in contentItems:
      let
        keyBytes = ContentKeyByteList.init(hexToSeqByte(contentItem[0]))
        offerValueBytes = hexToSeqByte(contentItem[1])

      contentOffers.add(ContentKV(contentKey: keyBytes, content: offerValueBytes))

    let offerResult = (await p.offer(node, contentOffers)).valueOr:
      raise newException(ValueError, $error)

    SSZ.encode(offerResult).to0xHex()

  rpcServer.rpc("portal_historyGetContent") do(contentKey: string) -> ContentInfo:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(keyBytes).valueOr:
        raise invalidKeyErr()

    p.getLocalContent(keyBytes, contentId).isErrOr:
      return ContentInfo(content: value.to0xHex(), utpTransfer: false)

    let
      contentLookupResult = (await p.contentLookup(keyBytes, contentId)).valueOr:
        raise contentNotFoundErr()
      valueBytes = contentLookupResult.content

    # Note:
    # Validate the content before returning & storing it. This is currently
    # quite ambiguously described in the specifications. Doing it anyhow as it
    # is rather a high level call.
    # TODO: Should lookup retries be done in case validation fails?
    (await n.validateContent(valueBytes, keyBytes)).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, valueBytes, cacheContent = true)

    ContentInfo(
      content: contentLookupResult.content.to0xHex(),
      utpTransfer: contentLookupResult.utpTransfer,
    )

  rpcServer.rpc("portal_historyTraceGetContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(keyBytes).valueOr:
        raise invalidKeyErr()

    p.getLocalContent(keyBytes, contentId).isErrOr:
      # TODO: Fill in the trace field here.
      return TraceContentLookupResult(content: Opt.some(value), utpTransfer: false)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    let
      res = await p.traceContentLookup(keyBytes, contentId)
      valueBytes = res.content.valueOr:
        let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
        raise contentNotFoundErrWithTrace(data)

    # Note: Same remark as for `portal_historyGetContent`
    (await n.validateContent(valueBytes, keyBytes)).isOkOr:
      raise invalidValueErr()
    p.storeContent(keyBytes, contentId, valueBytes, cacheContent = true)

    res

  rpcServer.rpc("portal_historyStore") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      offerValueBytes = hexToSeqByte(contentValue)
      contentId = p.toContentId(keyBytes).valueOr:
        raise invalidKeyErr()

    p.storeContent(keyBytes, contentId, offerValueBytes)

  rpcServer.rpc("portal_historyLocalContent") do(contentKey: string) -> string:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(keyBytes).valueOr:
        raise invalidKeyErr()

      valueBytes = p.getLocalContent(keyBytes, contentId).valueOr:
        raise contentNotFoundErr()

    valueBytes.to0xHex()

  rpcServer.rpc("portal_historyPutContent") do(
    contentKey: string, contentValue: string
  ) -> PutContentResult:
    let
      keyBytes = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(keyBytes).valueOr:
        raise invalidKeyErr()
      offerValueBytes = hexToSeqByte(contentValue)

      # TODO: validate and store content locally
      # Note: Not validating content as this would have a high impact on bridge
      # gossip performance. Specification is quite ambiguous on what kind of
      # validation should be done here anyhow.
      # As no validation is done here, the content is not stored locally.
      peerCount = await p.neighborhoodGossip(
        Opt.none(NodeId), ContentKeysList(@[keyBytes]), @[offerValueBytes]
      )

    PutContentResult(storedLocally: false, peerCount: peerCount)
