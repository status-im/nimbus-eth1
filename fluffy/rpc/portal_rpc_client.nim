# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/strutils,
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

type
  PortalRpcClient* = distinct RpcClient

  PortalRpcError* = enum
    ContentNotFound
    InvalidContentKey
    InvalidContentValue
    ContentValidationFailed

proc init*(T: type PortalRpcClient, rpcClient: RpcClient): T =
  T(rpcClient)

func toPortalRpcError(e: ref CatchableError): PortalRpcError =
  if e.msg.contains("-39001"):
    ContentNotFound
  elif e.msg.contains("-32602"):
    InvalidContentKey
  else:
    raiseAssert(e.msg) # Shouldn't happen

proc historyLocalContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, PortalRpcError]] {.async: (raises: []).} =
  try:
    let content = await RpcClient(client).portal_historyLocalContent(contentKey)
    ok(content)
  except CatchableError as e:
    err(e.toPortalRpcError())

proc historyRecursiveFindContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, PortalRpcError]] {.async: (raises: []).} =
  try:
    let contentInfo =
      await RpcClient(client).portal_historyRecursiveFindContent(contentKey)
    ok(contentInfo.content)
  except CatchableError as e:
    err(e.toPortalRpcError())

template toBytes(content: string): seq[byte] =
  try:
    hexToSeqByte(content)
  except ValueError as e:
    raiseAssert(e.msg)

proc historyGetContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, PortalRpcError]] {.async: (raises: []).} =
  # Look up the content from the local db before trying to get it from the network
  let content = (await client.historyLocalContent(contentKey)).valueOr:
    if error == ContentNotFound:
      ?await client.historyRecursiveFindContent(contentKey)
    else:
      return err(error)
  ok(content)

proc historyGetBlockHeader*(
    client: PortalRpcClient, blockHash: BlockHash, validateContent = true
): Future[Result[BlockHeader, PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the block header for the given hash from the Portal History Network.
  ## The data is first looked up in the node's local database before trying to
  ## fetch it from the network.
  ##
  ## Note: This does not validate that the returned header is part of the canonical
  ## chain, it only validates that the header matches the block hash. For example,
  ## a malicious portal node could return a valid but non-canonical header such
  ## as an uncle block that matches the block hash. For this reason the caller
  ## needs to use another method to verify the header is part of the canonical chain.

  let
    contentKey = blockHeaderContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.historyGetContent(contentKey)
    headerWithProof = decodeSsz(content.toBytes(), BlockHeaderWithProof).valueOr:
      return err(InvalidContentValue)
    headerBytes = headerWithProof.header.asSeq()

  if validateContent:
    validateBlockHeaderBytes(headerBytes, blockHash).isOkOr:
      return err(ContentValidationFailed)
  else:
    decodeRlp(headerBytes, BlockHeader).isOkOr:
      return err(InvalidContentValue)

proc historyGetBlockBody*(
    client: PortalRpcClient, blockHeader: BlockHeader, validateContent = true
): Future[Result[BlockBody, PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the block body for the given block header from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. If you have the block header then this
  ## function should be preferred over the one below which does an extra call to
  ## lookup the block header by blockHash.

  let
    contentKey = blockBodyContentKey(blockHeader.blockHash()).encode().asSeq().to0xHex()
    content = ?await client.historyGetContent(contentKey)

  if validateContent:
    validateBlockBodyBytes(content.toBytes(), blockHeader).isOkOr:
      return err(ContentValidationFailed)
  else:
    decodeBlockBodyBytes(content.toBytes()).isOkOr:
      return err(InvalidContentValue)

proc historyGetBlockBody*(
    client: PortalRpcClient, blockHash: BlockHash, validateContent = true
): Future[Result[BlockBody, PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the block body for the given block hash from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. The block header is fetched first and
  ## then the block body.

  let
    contentKey = blockBodyContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.historyGetContent(contentKey)
    blockHeader = ?await client.historyGetBlockHeader(blockHash)

  if validateContent:
    validateBlockBodyBytes(content.toBytes(), blockHeader).isOkOr:
      return err(ContentValidationFailed)
  else:
    decodeBlockBodyBytes(content.toBytes()).isOkOr:
      return err(InvalidContentValue)

proc historyGetReceipts*(
    client: PortalRpcClient, blockHeader: BlockHeader, validateContent = true
): Future[Result[seq[Receipt], PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block header from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. If you have the block header then this
  ## function should be preferred over the one below which does an extra call to
  ## lookup the block header by blockHash.

  let
    contentKey = receiptsContentKey(blockHeader.blockHash()).encode().asSeq().to0xHex()
    content = ?await client.historyGetContent(contentKey)

  if validateContent:
    validateReceiptsBytes(content.toBytes(), blockHeader.receiptsRoot).isOkOr:
      return err(ContentValidationFailed)
  else:
    let receipts = decodeSsz(content.toBytes(), PortalReceipts).valueOr:
      return err(InvalidContentValue)
    seq[Receipt].fromPortalReceipts(receipts).isOkOr:
      return err(InvalidContentValue)

proc historyGetReceipts*(
    client: PortalRpcClient, blockHash: BlockHash, validateContent = true
): Future[Result[seq[Receipt], PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block hash from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. The block header is fetched first and
  ## then the receipts.

  let
    contentKey = receiptsContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.historyGetContent(contentKey)
    blockHeader = ?await client.historyGetBlockHeader(blockHash)

  if validateContent:
    validateReceiptsBytes(content.toBytes(), blockHeader.receiptsRoot).isOkOr:
      return err(ContentValidationFailed)
  else:
    let receipts = decodeSsz(content.toBytes(), PortalReceipts).valueOr:
      return err(InvalidContentValue)
    seq[Receipt].fromPortalReceipts(receipts).isOkOr:
      return err(InvalidContentValue)
