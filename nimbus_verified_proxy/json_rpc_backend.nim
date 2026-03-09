# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/uri,
  stint,
  json_rpc/[rpcclient, rpcproxy],
  web3/[eth_api, eth_api_types],
  ./engine/types,
  ./nimbus_verified_proxy_conf

type JsonRpcClient* = ref object
  url: string
  case kind*: ClientKind
  of Http:
    httpClient: RpcHttpClient
  of WebSocket:
    wsClient: RpcWebSocketClient

template resolveClient(client: JsonRpcClient): RpcClient =
  case client.kind
  of Http: client.httpClient
  of WebSocket: client.wsClient

proc init*(T: type JsonRpcClient, url: string): EngineResult[JsonRpcClient] =
  let scheme = parseUri(url).scheme.toLowerAscii()
  case scheme
  of "http", "https":
    ok(JsonRpcClient(url: url, kind: Http, httpClient: newRpcHttpClient()))
  of "ws", "wss":
    ok(JsonRpcClient(url: url, kind: WebSocket, wsClient: newRpcWebSocketClient()))
  else:
    err((BackendError, "Invalid URL scheme: " & scheme, UNTAGGED))

proc start*(
    client: JsonRpcClient
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  try:
    case client.kind
    of Http:
      await client.httpClient.connect(client.url)
    of WebSocket:
      await client.wsClient.connect(uri = client.url, compression = false, flags = {})
    ok()
  except JsonRpcError as e:
    return err((BackendError, e.msg, UNTAGGED))

proc stop*(client: JsonRpcClient): Future[void] {.async: (raises: []).} =
  await client.resolveClient().close()

template rpcCall(body: untyped): untyped =
  try:
    body
  except CancelledError as e:
    raise e
  except RpcPostError as e:
    result = err(typeof(result), (BackendEncodingError, e.msg, UNTAGGED))
    return
  except ErrorResponse as e:
    result = err(typeof(result), (BackendFetchError, e.msg, UNTAGGED))
    return
  except JsonRpcError as e:
    result = err(typeof(result), (BackendDecodingError, e.msg, UNTAGGED))
    return
  except InvalidResponse as e:
    result = err(typeof(result), (BackendDecodingError, e.msg, UNTAGGED))
    return
  except CatchableError as e:
    result = err(typeof(result), (BackendError, e.msg, UNTAGGED))
    return

proc getEthApiBackend*(client: JsonRpcClient): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      rpcCall:
        ok(await client.resolveClient().eth_chainId())

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        let res =
          await client.resolveClient().eth_getBlockByHash(blkHash, fullTransactions)
        if res.isNil():
          return err(
            (BackendFetchError, "Obtained nil response for the RPC request", UNTAGGED)
          )
        ok(res)

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        let res =
          await client.resolveClient().eth_getBlockByNumber(blkNum, fullTransactions)
        if res.isNil():
          return err(
            (BackendFetchError, "Obtained nil response for the RPC request", UNTAGGED)
          )
        ok(res)

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(await client.resolveClient().eth_getProof(address, slots, blockId))

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(await client.resolveClient().eth_createAccessList(args, blockId))

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(await client.resolveClient().eth_getCode(address, blockId))

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        let res = await client.resolveClient().eth_getTransactionByHash(txHash)
        if res.isNil():
          return err(
            (BackendFetchError, "Obtained nil response for the RPC request", UNTAGGED)
          )
        ok(res)

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        let res = await client.resolveClient().eth_getTransactionReceipt(txHash)
        if res.isNil():
          return err(
            (BackendFetchError, "Obtained nil response for the RPC request", UNTAGGED)
          )
        ok(res)

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
        async: (raises: [CancelledError])
    .} =
      rpcCall:
        ok(await client.resolveClient().eth_getBlockReceipts(blockId))

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(await client.resolveClient().eth_getLogs(filterOptions))

    feeHistoryProc = proc(
        blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(
          await client.resolveClient().eth_feeHistory(
            blockCount, newestBlock, rewardPercentiles
          )
        )

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      rpcCall:
        ok(await client.resolveClient().eth_sendRawTransaction(txBytes))

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
    eth_getTransactionReceipt: getTransactionReceiptProc,
    eth_feeHistory: feeHistoryProc,
    eth_sendRawTransaction: sendRawTxProc,
  )
