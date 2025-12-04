# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/rpcserver,
  json_serialization/std/tables,
  stew/byteutils,
  ../common/common_types,
  ../network/wire/portal_protocol,
  ../network/history/history_network,
  ../network/history/history_validation,
  ../network/history/history_endpoints,
  ./rpc_types

export tables

# Portal History Network JSON-RPC API
# Note:
# - Not all lower level API calls are implemented as they are typically only used for (Hive)
# testing and it is not clear yet if this will be needed in the future.
# - Added two non specified methods:
#   - portal_historyGetBlockBody
#   - portal_historyGetReceipts
# These methods to be used for EL client integration.
# They require the Header parameter in order for validation on the JSON-RPC server side (= Portal node).

ContentInfo.useDefaultSerializationIn JrpcConv
TraceContentLookupResult.useDefaultSerializationIn JrpcConv
TraceObject.useDefaultSerializationIn JrpcConv
FailureInfo.useDefaultSerializationIn JrpcConv
NodeMetadata.useDefaultSerializationIn JrpcConv
TraceResponse.useDefaultSerializationIn JrpcConv

# TODO: It would be cleaner to use the existing getContent call for
# less code duplication + automatic retries, but the specific error messages + extra content
# info would need to be added to the existing calls.
proc installPortalHistoryApiHandlers*(rpcServer: RpcServer, n: HistoryNetwork) =
  rpcServer.rpc("portal_historyGetContent") do(contentKeyBytes: string) -> ContentInfo:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      contentKey = decode(contentKeyByteList).valueOr:
        raise invalidContentKeyError()
      contentId = toContentId(contentKey)

    n.portalProtocol.getLocalContent(contentKeyByteList, contentId).isErrOr:
      let content = value.to0xHex()
      return ContentInfo(content: content, utpTransfer: false)

    let
      contentLookupResult = (
        await n.portalProtocol.contentLookup(contentKeyByteList, contentId)
      ).valueOr:
        raise contentNotFoundErr()
      content = contentLookupResult.content.to0xHex()
    ContentInfo(content: content, utpTransfer: contentLookupResult.utpTransfer)

  rpcServer.rpc("portal_historyTraceGetContent") do(
    contentKeyBytes: string
  ) -> TraceContentLookupResult:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      contentKey = decode(contentKeyByteList).valueOr:
        raise invalidContentKeyError()
      contentId = toContentId(contentKey)

    n.portalProtocol.getLocalContent(contentKeyByteList, contentId).isErrOr:
      return TraceContentLookupResult(
        content: Opt.some(value),
        utpTransfer: false,
        trace: TraceObject(
          origin: n.localNode.id,
          targetId: contentId,
          receivedFrom: Opt.some(n.localNode.id),
        ),
      )

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    let
      res = await n.portalProtocol.traceContentLookup(contentKeyByteList, contentId)
      valueBytes = res.content.valueOr:
        let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
        raise contentNotFoundErrWithTrace(data)

    res

  rpcServer.rpc("portal_historyPutContent") do(
    contentKeyBytes: string, contentValueBytes: string
  ) -> PutContentResult:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      _ = decode(contentKeyByteList).valueOr:
        raise invalidContentKeyError()
      offerValueBytes = hexToSeqByte(contentValueBytes)

      # Note: Not validating content as this would have a high impact on bridge
      # gossip performance. It is also not possible without having the Header
      gossipMetadata = await n.portalProtocol.neighborhoodGossip(
        Opt.none(NodeId),
        ContentKeysList(@[contentKeyByteList]),
        @[offerValueBytes],
        enableNodeLookup = true,
      )

    PutContentResult(
      storedLocally: false,
      peerCount: gossipMetadata.successCount,
      acceptMetadata: AcceptMetadata(
        acceptedCount: gossipMetadata.acceptedCount,
        genericDeclineCount: gossipMetadata.genericDeclineCount,
        alreadyStoredCount: gossipMetadata.alreadyStoredCount,
        notWithinRadiusCount: gossipMetadata.notWithinRadiusCount,
        rateLimitedCount: gossipMetadata.rateLimitedCount,
        transferInProgressCount: gossipMetadata.transferInProgressCount,
      ),
    )

  rpcServer.rpc("portal_historyStore") do(
    contentKeyBytes: string, contentValueBytes: string
  ) -> bool:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      offerValueBytes = hexToSeqByte(contentValueBytes)
      contentId = n.portalProtocol.toContentId(contentKeyByteList).valueOr:
        raise invalidContentKeyError()

    n.portalProtocol.storeContent(contentKeyByteList, contentId, offerValueBytes)

  rpcServer.rpc("portal_historyLocalContent") do(contentKeyBytes: string) -> string:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      contentId = n.portalProtocol.toContentId(contentKeyByteList).valueOr:
        raise invalidContentKeyError()

      valueBytes = n.portalProtocol.getLocalContent(contentKeyByteList, contentId).valueOr:
        raise contentNotFoundErr()

    valueBytes.to0xHex()

  rpcServer.rpc("portal_historyGetBlockBody") do(headerBytes: string) -> string:
    let header = decodeRlp(hexToSeqByte(headerBytes), Header).valueOr:
      raise applicationError((code: -39010, msg: "Failed to decode header: " & error))

    let blockBody = (await n.getBlockBody(header)).valueOr:
      raise contentNotFoundErr()

    rlp.encode(blockBody).to0xHex()

  rpcServer.rpc("portal_historyGetReceipts") do(headerBytes: string) -> string:
    let header = decodeRlp(hexToSeqByte(headerBytes), Header).valueOr:
      raise applicationError((code: -39010, msg: "Failed to decode header: " & error))

    let receipts = (await n.getReceipts(header)).valueOr:
      raise contentNotFoundErr()

    rlp.encode(receipts).to0xHex()
