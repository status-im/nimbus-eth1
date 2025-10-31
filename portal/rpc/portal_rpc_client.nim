# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_serialization,
  chronos,
  stew/byteutils,
  results,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  json_rpc/rpcclient,
  ../common/common_types,
  ../network/history/[history_content, history_validation],
  ./rpc_calls/[rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls],
  ./rpc_types

export
  rpcclient, rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls, results,
  rpc_types

type
  PortalRpcClient* = distinct RpcClient

  PortalErrorResponse* = object
    code*: int
    message*: string

const
  InvalidJsonRpcError* = -1
  ReceivedInvalidDataError* = -2

proc init*(T: type PortalRpcClient, rpcClient: RpcClient): T =
  T(rpcClient)

func toPortalRpcError*(error: string): PortalErrorResponse =
  try:
    Json.decode(error, PortalErrorResponse)
  except SerializationError as e:
    PortalErrorResponse(code: InvalidJsonRpcError, message: error)

template toBytes(content: string): seq[byte] =
  try:
    hexToSeqByte(content)
  except ValueError as e:
    raiseAssert(e.msg)

proc historyGetBlockBody*(
    client: PortalRpcClient, header: Header
): Future[Result[BlockBody, PortalErrorResponse]] {.async: (raises: []).} =
  ## Fetches the block body for the given block header from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. The block header needs to be passed
  ## in order to run the content validation.
  let
    headerBytes = rlp.encode(header).to0xHex()
    content =
      try:
        await RpcClient(client).portal_historyGetBlockBody(headerBytes)
      except CatchableError as e:
        return err(e.msg.toPortalRpcError())
    blockBody = decodeRlp(content.toBytes(), BlockBody).valueOr:
      return err(
        PortalErrorResponse(
          code: ReceivedInvalidDataError,
          message: "Failed to decode received BlockBody: " & error,
        )
      )

  ok(blockBody)

proc historyGetReceipts*(
    client: PortalRpcClient, header: Header
): Future[Result[StoredReceipts, PortalErrorResponse]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block header from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. The block header needs to be passed
  ## in order to run the content validation.
  let
    headerBytes = rlp.encode(header).to0xHex()
    content =
      try:
        await RpcClient(client).portal_historyGetReceipts(headerBytes)
      except CatchableError as e:
        return err(e.msg.toPortalRpcError())
    receipts = decodeRlp(content.toBytes(), StoredReceipts).valueOr:
      return err(
        PortalErrorResponse(
          code: ReceivedInvalidDataError,
          message: "Failed to decode received StoredReceipts: " & error,
        )
      )

  ok(receipts)
