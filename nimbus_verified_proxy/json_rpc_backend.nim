# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  stint,
  presto/client,
  eth/common/keys, # used for keys.rng
  json_rpc/[rpcclient, rpcproxy],
  web3/[eth_api, eth_api_types],
  ./engine/types,
  ./nimbus_verified_proxy_conf

type
  JsonRpcClient* = ref object
    case kind*: ClientKind
    of Http:
      httpClient: RpcHttpClient
    of WebSocket:
      wsClient: RpcWebSocketClient

  JsonRpcClientPool* = ref object
    rng: ref HmacDrbgContext
    urls: seq[string]
    clients: seq[JsonRpcClient]

proc new*(T: type JsonRpcClientPool): T =
  let rng = keys.newRng()
  JsonRpcClientPool(rng: rng, urls: @[], clients: @[])

template resolveClient(client: JsonRpcClient): RpcClient =
  case client.kind
  of Http: client.httpClient
  of WebSocket: client.wsClient

proc addEndpoints*(
    pool: JsonRpcClientPool, urlList: seq[Web3Url]
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  for endpoint in urlList:
    if endpoint.web3Url in pool.urls:
      continue

    try:
      case endpoint.kind
      of HttpUrl:
        let client = JsonRpcClient(kind: Http, httpClient: newRpcHttpClient())
        await client.httpClient.connect(endpoint.web3Url)
        pool.clients.add(client)
        pool.urls.add(endpoint.web3Url)
      of WsUrl:
        let client = JsonRpcClient(kind: WebSocket, wsClient: newRpcWebSocketClient())
        await client.wsClient.connect(
          uri = endpoint.web3Url, compression = false, flags = {}
        )
        pool.clients.add(client)
        pool.urls.add(endpoint.web3Url)
    except JsonRpcError as e:
      return err((BackendError, e.msg))

  ok()

proc closeAll*(pool: JsonRpcClientPool) {.async: (raises: []).} =
  for client in pool.clients:
    await client.resolveClient().close()

  pool.clients.setLen(0)
  pool.urls.setLen(0)

proc getClientFromPool(pool: JsonRpcClientPool): JsonRpcClient =
  var randomNum: uint64
  pool.rng[].generate(randomNum)

  pool.clients[randomNum mod uint64(pool.clients.len)]

proc getEthApiBackend*(pool: JsonRpcClientPool): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(await pool.getClientFromPool().resolveClient().eth_chainId())
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.getClient().eth_getBlockByHash(blkHash, fullTransactions)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request"))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.getClient().eth_getBlockByNumber(blkNum, fullTransactions)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request"))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await pool.getClientFromPool().resolveClient().eth_getProof(
            address, slots, blockId
          )
        )
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await pool.getClientFromPool().resolveClient().eth_createAccessList(
            args, blockId
          )
        )
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await pool.getClientFromPool().resolveClient().eth_getCode(address, blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.getClient().eth_getTransactionByHash(txHash)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request"))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
      try:
        let res = await client.getClient().eth_getTransactionReceipt(txHash)
        if res.isNil():
          return err((BackendFetchError, "Obtained nil response for the RPC request"))
        ok(res)
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
        async: (raises: [CancelledError])
    .} =
      try:
        ok(await pool.getClientFromPool().resolveClient().eth_getBlockReceipts(blockId))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
      try:
        ok(await pool.getClientFromPool().resolveClient().eth_getLogs(filterOptions))
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    feeHistoryProc = proc(
        blockCount: Quantity,
        newestBlock: BlockTag,
        rewardPercentiles: Opt[seq[float64]],
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await pool.getClientFromPool().resolveClient().eth_feeHistory(
            blockCount, newestBlock, rewardPercentiles
          )
        )
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      try:
        ok(
          await pool.getClientFromPool().resolveClient().eth_sendRawTransaction(txBytes)
        )
      except CancelledError as e:
        raise e
      except RpcPostError as e:
        return err((BackendEncodingError, e.msg))
      except ErrorResponse as e:
        return err((BackendFetchError, e.msg))
      except JsonRpcError as e:
        return err((BackendDecodingError, e.msg))
      except InvalidResponse as e:
        return err((BackendDecodingError, e.msg))
      except CatchableError as e:
        return err((BackendError, e.msg))

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
