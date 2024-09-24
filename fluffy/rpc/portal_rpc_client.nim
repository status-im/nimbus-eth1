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
    header = ?decodeRlp(headerWithProof.header.asSeq(), BlockHeader)
  ok(header)

proc historyRecursiveFindBlockBody*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[BlockBody, string]] {.async: (raises: []).} =
  let
    contentKeyBytes = blockBodyContentKey(blockHash).encode().asSeq()
    content = ?await client.historyRecursiveFindContent(contentKeyBytes.to0xHex())
    contentBytes =
      try:
        hexToSeqByte(content)
      except ValueError as e:
        return err(e.msg)
    blockBody = ?decodeBlockBodyBytes(contentBytes)
  ok(blockBody)

proc historyRecursiveFindReceipts*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[seq[Receipt], string]] {.async: (raises: []).} =
  let
    contentKeyBytes = receiptsContentKey(blockHash).encode().asSeq()
    content = ?await client.historyRecursiveFindContent(contentKeyBytes.to0xHex())
    contentBytes =
      try:
        hexToSeqByte(content)
      except ValueError as e:
        return err(e.msg)
    receipts =
      ?seq[Receipt].fromPortalReceipts(?decodeSsz(contentBytes, PortalReceipts))
  ok(receipts)
