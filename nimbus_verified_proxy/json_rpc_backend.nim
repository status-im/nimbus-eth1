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

type JsonRpcClient* = ref object
  url: string
  case kind*: ClientKind
  of Http:
    httpClient: RpcHttpClient
  of WebSocket:
    wsClient: RpcWebSocketClient

proc init*(T: type JsonRpcClient, url: Web3Url): JsonRpcClient =
  case url.kind
  of HttpUrl:
    JsonRpcClient(kind: Http, httpClient: newRpcHttpClient(), url: url.web3Url)
  of WsUrl:
    JsonRpcClient(kind: WebSocket, wsClient: newRpcWebSocketClient(), url: url.web3Url)

proc start*(
    client: JsonRpcClient
): Future[Result[void, string]] {.async: (raises: []).} =
  try:
    case client.kind
    of Http:
      await client.httpClient.connect(client.url)
    of WebSocket:
      await client.wsClient.connect(uri = client.url, compression = false, flags = {})
  except CatchableError as e:
    return err(e.msg)

  ok()

template getClient(client: JsonRpcClient): RpcClient =
  case client.kind
  of Http: client.httpClient
  of WebSocket: client.wsClient

proc getEthApiBackend*(client: JsonRpcClient): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[UInt256] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_chainId()
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getBlockByHash(blkHash, fullTransactions)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getBlockByNumber(blkNum, fullTransactions)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getProof(address, slots, blockId)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_createAccessList(args, blockId)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[seq[byte]] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getCode(address, blockId)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[TransactionObject] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getTransactionByHash(txHash)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[ReceiptObject] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getTransactionReceipt(txHash)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[Opt[seq[ReceiptObject]]] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getBlockReceipts(blockId)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[seq[LogObject]] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_getLogs(filterOptions)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    feeHistoryProc = proc(
        blockCount: Quantity,
        newestBlock: BlockTag,
        rewardPercentiles: Opt[seq[float64]],
    ): Future[FeeHistoryResult] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_feeHistory(
          blockCount, newestBlock, rewardPercentiles
        )
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[Hash32] {.async: (raises: [CancelledError]).} =
      try:
        await client.getClient().eth_sendRawTransaction(txBytes)
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

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

proc stop*(client: JsonRpcClient) {.async: (raises: [CancelledError]).} =
  try:
    await client.getClient().close()
  except CatchableError:
    raise newException(CancelledError, "coudln't close the json rpc client")
