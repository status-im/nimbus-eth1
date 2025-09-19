# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  json_rpc/[rpcclient, rpcproxy],
  web3/[eth_api, eth_api_types, conversions],
  json_serialization,
  stint,
  ./types,
  ./nimbus_verified_proxy_conf

type
  JsonRpcBackend* = object of EthApiBackend
    url: string
    case kind*: ClientKind
    of Http:
      httpClient: RpcHttpClient
    of WebSocket:
      wsClient: RpcWebSocketClient

proc client(backend: JsonRpcBackend): RpcClient =
  case backend.kind:
  of Http:
    backend.httpClient
  of WebSocket:
    backend.wsClient

proc init*(T: type JsonRpcBackend, url: Web3Url): T =
  var backend: JsonRpcBackend

  if url.kind == HttpUrl: 
    backend = JsonRpcBackend(
      kind: Http,
      httpClient: newRpcHttpClient(),
      url: url.web3Url
    )
  elif url.kind == WsUrl:
    backend = JsonRpcBackend(
      kind: WebSocket,
      wsClient: newRpcWebSocketClient(),
      url: url.web3Url
    )

  backend.eth_chainId = proc(): Future[UInt256] {.async: (raw: true).} =
    backend.client.eth_chainId()

  backend.eth_getBlockByHash = proc(
      blkHash: Hash32, fullTransactions: bool
  ): Future[BlockObject] {.async: (raw: true).} =
    backend.client.eth_getBlockByHash(blkHash, fullTransactions)

  backend.eth_getBlockByNumber = proc(
      blkNum: BlockTag, fullTransactions: bool
  ): Future[BlockObject] {.async: (raw: true).} =
    backend.client.eth_getBlockByNumber(blkNum, fullTransactions)

  backend.eth_getProof = proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[ProofResponse] {.async: (raw: true).} =
    backend.client.eth_getProof(address, slots, blockId)

  backend.eth_createAccessList = proc(
      args: TransactionArgs, blockId: BlockTag
  ): Future[AccessListResult] {.async: (raw: true).} =
    backend.client.eth_createAccessList(args, blockId)

  backend.eth_getCode = proc(
      address: Address, blockId: BlockTag
  ): Future[seq[byte]] {.async: (raw: true).} =
    backend.client.eth_getCode(address, blockId)

  backend.eth_getTransactionByHash = proc(
      txHash: Hash32
  ): Future[TransactionObject] {.async: (raw: true).} =
    backend.client.eth_getTransactionByHash(txHash)

  backend.eth_getTransactionReceipt = proc(
      txHash: Hash32
  ): Future[ReceiptObject] {.async: (raw: true).} =
    backend.client.eth_getTransactionReceipt(txHash)

  backend.eth_getBlockReceipts = proc(
      blockId: BlockTag
  ): Future[Opt[seq[ReceiptObject]]] {.async: (raw: true).} =
    backend.client.eth_getBlockReceipts(blockId)

  backend.eth_getLogs = proc(
      filterOptions: FilterOptions
  ): Future[seq[LogObject]] {.async: (raw: true).} =
    backend.client.eth_getLogs(filterOptions)

  return backend

proc start*(backend: JsonRpcBackend): Future[Result[void, string]] {.async.} =
  try:
    if backend.kind == Http:
      await backend.httpClient.connect(backend.url)
    elif backend.kind == WebSocket:
      await backend.wsClient.connect(uri = backend.url, compression = false, flags = {})
  except CatchableError as e:
    return err(e.msg)

  ok()

proc stop*(backend: JsonRpcBackend) {.async.} = 
  await backend.client.close()
