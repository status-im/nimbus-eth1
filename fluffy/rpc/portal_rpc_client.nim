# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronos,
  stew/byteutils,
  results,
  eth/common/eth_types,
  json_rpc/rpcclient,
  ../common/common_types,
  ../network/history/[history_content, history_network],
  ./rpc_calls/[rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls]

export
  rpcclient, rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls, results,
  eth_types

type PortalRpcClient* = distinct RpcClient

# TODO: How to check if rpc client is connected?
# TODO: Should we implement a reconnect mechanism if disconnected? Note that HTTP
# behaves differently from WS. If the rpc server goes down, then the WS connection is
# lost and requests will fail even after the server comes back up, where as HTTP
# doesn't have an real connection so the next request will be ok once the server comes back up.
# TODO: Should we implement retries for RPC calls?
# TODO: Note that the WS client appears to only be able to handle one concurrent call at a time
# while the HTTP client can handle multiple. Either we fix this on the Rpc Client library side
# or if this is a limitation of the WebSocket protocol then should document the behaviour here
# TODO: should we verify content or just trust the content coming from the rpc server?
proc init*(T: type PortalRpcClient, rpcClient: RpcClient): T =
  T(rpcClient)

proc historyRecursiveFindContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, string]] {.async: (raises: []).} =
  try:
    let contentInfo =
      await RpcClient(client).portal_historyRecursiveFindContent(contentKey)
    ok(contentInfo.content)
  except CatchableError as e:
    err(e.msg)

#to0xHex
#hexToSeqByte
# func blockBodyContentKey*(hash: BlockHash): ContentKey =
#   ContentKey(contentType: blockBody, blockBodyKey: BlockKey(blockHash: hash))

# func receiptsContentKey*(hash: BlockHash): ContentKey =
#   ContentKey(contentType: receipts, receiptsKey: BlockKey(blockHash: hash))

proc historyRecursiveFindBlockHeader*(
    client: PortalRpcClient, blockNumOrHash: uint64 | BlockHash
): Future[Result[BlockHeader, string]] {.async: (raises: []).} =
  let
    contentKeyBytes = blockHeaderContentKey(blockNumOrHash).encode().asSeq()
    content = ?await client.historyRecursiveFindContent(contentKeyBytes.to0xHex())
    contentBytes =
      try:
        hexToSeqByte(content)
      except ValueError as e:
        return err(e.msg)
    headerWithProof = ?decodeSsz(contentBytes, BlockHeaderWithProof)
    header = ?validateBlockHeaderBytes(headerWithProof.header.asSeq(), blockHash)
  ok(header)

proc historyRecursiveFindBlockBody*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[BlockBody, string]] {.async: (raises: []).} =
  discard

proc historyRecursiveFindReceipts*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[seq[Receipt], string]] {.async: (raises: []).} =
  discard
