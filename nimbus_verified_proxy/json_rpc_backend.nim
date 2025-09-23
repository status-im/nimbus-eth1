# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  stint,
  json_rpc/[rpcclient, rpcproxy],
  web3/[eth_api, eth_api_types],
  ./engine/types,
  ./nimbus_verified_proxy_conf

type
  JsonRpcBackend* = ref object
    url: string
    case kind*: ClientKind
    of Http:
      httpClient: RpcHttpClient
    of WebSocket:
      wsClient: RpcWebSocketClient

proc init*(T: type JsonRpcBackend, url: Web3Url): JsonRpcBackend =
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

  backend

proc start*(backend: JsonRpcBackend): Future[Result[void, string]] {.async.} =
  try:
    if backend.kind == Http:
      await backend.httpClient.connect(backend.url)
    elif backend.kind == WebSocket:
      await backend.wsClient.connect(uri = backend.url, compression = false, flags = {})
  except CatchableError as e:
    return err(e.msg)

  ok()


proc getEthApiBackend*(backend: JsonRpcBackend): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[UInt256] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_chainId()
      of WebSocket:
        backend.wsClient.eth_chainId()

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getBlockByHash(blkHash, fullTransactions)
      of WebSocket:
        backend.wsClient.eth_getBlockByHash(blkHash, fullTransactions)

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getBlockByNumber(blkNum, fullTransactions)
      of WebSocket:
        backend.wsClient.eth_getBlockByNumber(blkNum, fullTransactions)

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getProof(address, slots, blockId)
      of WebSocket:
        backend.wsClient.eth_getProof(address, slots, blockId)

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_createAccessList(args, blockId)
      of WebSocket:
        backend.wsClient.eth_createAccessList(args, blockId)

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[seq[byte]] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getCode(address, blockId)
      of WebSocket:
        backend.wsClient.eth_getCode(address, blockId)

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[TransactionObject] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getTransactionByHash(txHash)
      of WebSocket:
        backend.wsClient.eth_getTransactionByHash(txHash)

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[ReceiptObject] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getTransactionReceipt(txHash)
      of WebSocket:
        backend.wsClient.eth_getTransactionReceipt(txHash)

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[Opt[seq[ReceiptObject]]] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getBlockReceipts(blockId)
      of WebSocket:
        backend.wsClient.eth_getBlockReceipts(blockId)

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[seq[LogObject]] {.async: (raw: true).} =
      case backend.kind:
      of Http:
        backend.httpClient.eth_getLogs(filterOptions)
      of WebSocket:
        backend.wsClient.eth_getLogs(filterOptions)

  debugEcho "here we are"

  EthApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
    eth_getBlockReceipts: getBlockReceiptsProc,
    eth_getLogs: getLogsProc,
    eth_getTransactionByHash: getTransactionByHashProc,
    eth_getTransactionReceipt: getTransactionReceiptProc
  )

proc stop*(backend: JsonRpcBackend) {.async.} = 
  case backend.kind:
  of Http:
    await backend.httpClient.close()
  of WebSocket:
    await backend.wsClient.close()
