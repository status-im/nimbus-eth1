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

proc historyLocalContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[Opt[string], string]] {.async: (raises: []).} =
  try:
    let content = await RpcClient(client).portal_historyLocalContent(contentKey)
    ok(Opt.some(content))
  except ApplicationError as e:
    # Content not found
    ok(Opt.none(string))
  except CatchableError as e:
    err(e.msg)

proc historyRecursiveFindContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, string]] {.async: (raises: []).} =
  try:
    let contentInfo =
      await RpcClient(client).portal_historyRecursiveFindContent(contentKey)
    ok(contentInfo.content)
  except CatchableError as e:
    err(e.msg)

template toBytes(content: string): seq[byte] =
  try:
    hexToSeqByte(content)
  except ValueError as e:
    raiseAssert(e.msg)

template getHistoryContent(
    client: PortalRpcClient, contentKeyBytes: openArray[byte]
): untyped =
  # Look up the content from the local db before trying to get it from the network
  let
    contentKey = contentKeyBytes.to0xHex()
    maybeContent = ?await client.historyLocalContent(contentKey)
    content = maybeContent.valueOr:
      ?await client.historyRecursiveFindContent(contentKey)

  content.toBytes()

proc historyRecursiveFindBlockHeader*(
    client: PortalRpcClient, blockNumOrHash: uint64 | BlockHash
): Future[Result[BlockHeader, string]] {.async: (raises: []).} =
  ## Fetches the block header for the given block number or hash from the
  ## Portal History Network. The data is first looked up in the local database
  ## before trying to fetch it from the network.

  let
    contentKeyBytes = blockHeaderContentKey(blockNumOrHash).encode().asSeq()
    contentBytes = client.getHistoryContent(contentKeyBytes)
    headerWithProof = ?decodeSsz(contentBytes, BlockHeaderWithProof)

  validateBlockHeaderBytes(headerWithProof.header.asSeq(), blockNumOrHash)

proc historyRecursiveFindBlockBody*(
    client: PortalRpcClient, blockHeader: BlockHeader
): Future[Result[BlockBody, string]] {.async: (raises: []).} =
  ## Fetches the block body for the given block header from the Portal History
  ## Network. The data is first looked up in the local database before trying
  ## to fetch it from the network. If you have the block header then this function
  ## should be preferred over the one below which does an extra call to lookup the
  ## block header by blockHash.

  let
    contentKeyBytes = blockBodyContentKey(blockHeader.blockHash()).encode().asSeq()
    contentBytes = client.getHistoryContent(contentKeyBytes)

  validateBlockBodyBytes(contentBytes, blockHeader)

proc historyRecursiveFindBlockBody*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[BlockBody, string]] {.async: (raises: []).} =
  ## Fetches the block body for the given block hash from the Portal History
  ## Network. The data is first looked up in the local database before trying
  ## to fetch it from the network. The block header is fetched first and then
  ## the block body.

  let
    contentKeyBytes = blockBodyContentKey(blockHash).encode().asSeq()
    contentBytes = client.getHistoryContent(contentKeyBytes)
    blockHeader = ?await client.historyRecursiveFindBlockHeader(blockHash)

  validateBlockBodyBytes(contentBytes, blockHeader)

proc historyRecursiveFindReceipts*(
    client: PortalRpcClient, blockHeader: BlockHeader
): Future[Result[seq[Receipt], string]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block header from the Portal History
  ## Network. The data is first looked up in the local database before trying
  ## to fetch it from the network. If you have the block header then this function
  ## should be preferred over the one below which does an extra call to lookup the
  ## block header by blockHash.

  let
    contentKeyBytes = receiptsContentKey(blockHeader.blockHash()).encode().asSeq()
    contentBytes = client.getHistoryContent(contentKeyBytes)

  validateReceiptsBytes(contentBytes, blockHeader.receiptsRoot)

proc historyRecursiveFindReceipts*(
    client: PortalRpcClient, blockHash: BlockHash
): Future[Result[seq[Receipt], string]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block hash from the Portal History
  ## Network. The data is first looked up in the local database before trying
  ## to fetch it from the network. The block header is fetched first and then
  ## the receipts.

  let
    contentKeyBytes = receiptsContentKey(blockHash).encode().asSeq()
    contentBytes = client.getHistoryContent(contentKeyBytes)
    blockHeader = ?await client.historyRecursiveFindBlockHeader(blockHash)

  validateReceiptsBytes(contentBytes, blockHeader.receiptsRoot)
