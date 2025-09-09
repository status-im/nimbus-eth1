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
  ../network/history/history_content,
  ../network/history/history_validation,
  ./rpc_types

export tables

# Portal History Network JSON-RPC API
# Note:
# - This API is not part of the Portal Network specification yet.
# - Lower level API calls are not implemented as they are typically only used for (Hive)
# testing and it is not clear yet of this will be needed in the future.
# - Added the header parameter so that validation can happen on json-rpc server side,
# but it could also be moved to client side.
# - Could also make a less generic API

ContentInfo.useDefaultSerializationIn JrpcConv
TraceContentLookupResult.useDefaultSerializationIn JrpcConv
TraceObject.useDefaultSerializationIn JrpcConv
NodeMetadata.useDefaultSerializationIn JrpcConv
TraceResponse.useDefaultSerializationIn JrpcConv

# TODO: It would be cleaner to use the existing getContent/getBlockBody/getReceipts calls for
# less code duplication + automatic retries, but the specific error messages + extra content
# info would need to be added to the existing calls.
proc installPortalHistoryApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
  rpcServer.rpc("portal_historyGetContent") do(
    contentKeyBytes: string, headerBytes: string
  ) -> ContentInfo:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      contentKey = decode(contentKeyByteList).valueOr:
        raise invalidKeyErr()
      contentId = toContentId(contentKey)
      header = decodeRlp(hexToSeqByte(headerBytes), Header).valueOr:
        raise invalidRequest((code: -39005, msg: "Failed to decode header: " & error))

    p.getLocalContent(contentKeyByteList, contentId).isErrOr:
      return ContentInfo(content: value.to0xHex(), utpTransfer: false)

    let contentLookupResult = (await p.contentLookup(contentKeyByteList, contentId)).valueOr:
      raise contentNotFoundErr()

    validateContent(contentKey, contentLookupResult.content, header).isOkOr:
      p.banNode(
        contentLookupResult.receivedFrom.id,
        NodeBanDurationContentLookupFailedValidation,
      )
      raise invalidValueErr()

    p.storeContent(
      contentKeyByteList, contentId, contentLookupResult.content, cacheContent = true
    )

    ContentInfo(
      content: contentLookupResult.content.to0xHex(),
      utpTransfer: contentLookupResult.utpTransfer,
    )

  rpcServer.rpc("portal_historyTraceGetContent") do(
    contentKeyBytes: string, headerBytes: string
  ) -> TraceContentLookupResult:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      contentKey = decode(contentKeyByteList).valueOr:
        raise invalidKeyErr()
      contentId = toContentId(contentKey)
      header = decodeRlp(hexToSeqByte(headerBytes), Header).valueOr:
        raise invalidRequest((code: -39005, msg: "Failed to decode header: " & error))

    p.getLocalContent(contentKeyByteList, contentId).isErrOr:
      return TraceContentLookupResult(
        content: Opt.some(value),
        utpTransfer: false,
        trace: TraceObject(
          origin: p.localNode.id,
          targetId: contentId,
          receivedFrom: Opt.some(p.localNode.id),
        ),
      )

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    let
      res = await p.traceContentLookup(contentKeyByteList, contentId)
      valueBytes = res.content.valueOr:
        let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
        raise contentNotFoundErrWithTrace(data)

    validateContent(contentKey, valueBytes, header).isOkOr:
      if res.trace.receivedFrom.isSome():
        p.banNode(
          res.trace.receivedFrom.get(), NodeBanDurationContentLookupFailedValidation
        )
      raise invalidValueErr()

    p.storeContent(contentKeyByteList, contentId, valueBytes, cacheContent = true)

    res

  rpcServer.rpc("portal_historyPutContent") do(
    contentKeyBytes: string, contentValueBytes: string
  ) -> PutContentResult:
    let
      contentKeyByteList = ContentKeyByteList.init(hexToSeqByte(contentKeyBytes))
      _ = decode(contentKeyByteList).valueOr:
        raise invalidKeyErr()
      offerValueBytes = hexToSeqByte(contentValueBytes)

      # Note: Not validating content as this would have a high impact on bridge
      # gossip performance.
      # As no validation is done here, the content is not stored locally.
      # TODO: Add default on validation by optional validation parameter.
      gossipMetadata = await p.neighborhoodGossip(
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
