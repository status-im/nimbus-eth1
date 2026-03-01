# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
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

type JsonRpcClient* = ref object
  url: Web3Url
  case kind*: ClientKind
  of Http:
    httpClient: RpcHttpClient
  of WebSocket:
    wsClient: RpcWebSocketClient

template resolveClient(client: JsonRpcClient): RpcClient =
  case client.kind
  of Http: client.httpClient
  of WebSocket: client.wsClient

proc init*(T: type JsonRpcClient, url: Web3Url): EngineResult[JsonRpcClient] =
  case url.kind
  of HttpUrl:
    ok(JsonRpcClient(url: url, kind: Http, httpClient: newRpcHttpClient()))
  of WsUrl:
    ok(JsonRpcClient(url: url, kind: WebSocket, wsClient: newRpcWebSocketClient()))

proc start*(
    client: JsonRpcClient
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  try:
    case client.kind
    of Http:
      await client.httpClient.connect(client.url.web3Url)
    of WebSocket:
      await client.wsClient.connect(
        uri = client.url.web3Url, compression = false, flags = {}
      )
    ok()
  except JsonRpcError as e:
    return err((BackendError, e.msg, -1))

proc stop*(client: JsonRpcClient): Future[void] {.async: (raises: []).} =
  await client.resolveClient().close()

proc getEthApiBackend*(client: JsonRpcClient): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(await client.resolveClient().eth_chainId())
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res =
          await client.resolveClient().eth_getBlockByHash(blkHash, fullTransactions)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request", -1))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res =
          await client.resolveClient().eth_getBlockByNumber(blkNum, fullTransactions)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request", -1))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await client.resolveClient().eth_getProof(address, slots, blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await client.resolveClient().eth_createAccessList(args, blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await client.resolveClient().eth_getCode(address, blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.resolveClient().eth_getTransactionByHash(txHash)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request", -1))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.resolveClient().eth_getTransactionReceipt(txHash)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request", -1))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(await client.resolveClient().eth_getBlockReceipts(blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await client.resolveClient().eth_getLogs(filterOptions))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    feeHistoryProc = proc(
        blockCount: Quantity,
        newestBlock: BlockTag,
        rewardPercentiles: Opt[seq[float64]],
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await client.resolveClient().eth_feeHistory(
            blockCount, newestBlock, rewardPercentiles
          )
        )
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await client.resolveClient().eth_sendRawTransaction(txBytes))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg, -1))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg, -1))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg, -1))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg, -1))
      except CatchableError as e:
        return err((BackendError, e.msg, -1))

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
