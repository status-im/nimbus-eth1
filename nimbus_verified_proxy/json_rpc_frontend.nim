# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  stint,
  std/strutils,
  json_rpc/[rpcserver, rpcproxy],
  web3/[eth_api, eth_api_types],
  ../execution_chain/rpc/cors,
  ./engine/types,
  ./nimbus_verified_proxy_conf

type JsonRpcServer* = ref object
  case kind*: ClientKind #we reuse clientKind for servers also
  of Http:
    httpServer: RpcHttpServer
  of WebSocket:
    wsServer: RpcWebSocketServer

proc init*(T: type JsonRpcServer, url: Web3Url): EngineResult[JsonRpcServer] =
  let
    auth = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    parsedUrl = parseUri(url.web3Url)
    hostname = if parsedUrl.hostname == "": "127.0.0.1" else: parsedUrl.hostname
    port =
      if parsedUrl.port == "":
        8545
      else:
        try:
          parseInt(parsedUrl.port)
        except ValueError:
          return err((FrontendError, "Could not parse the port number"))

    listenAddress =
      try:
        initTAddress(hostname, port)
      except TransportAddressError as e:
        return err((FrontendError, e.msg))

  try:
    case url.kind
    of HttpUrl:
      return ok(
        JsonRpcServer(
          kind: Http,
          httpServer: newRpcHttpServer([listenAddress], RpcRouter.init(), auth),
        )
      )
    of WsUrl:
      let server =
        JsonRpcServer(kind: WebSocket, wsServer: newRpcWebSocketServer(listenAddress))

      server.wsServer.router = RpcRouter.init()
      return ok(server)
  except JsonRpcError as e:
    return err((FrontendError, e.msg))

func getServer(server: JsonRpcServer): RpcServer =
  case server.kind
  of Http: server.httpServer
  of WebSocket: server.wsServer

proc start*(server: JsonRpcServer): EngineResult[void] =
  try:
    case server.kind
    of Http:
      server.httpServer.start()
    of WebSocket:
      server.wsServer.start()
  except JsonRpcError as e:
    return err((FrontendError, e.msg))

  ok()

# this unpacks the result objects returned by frontend and translates result errors
# to exceptions. This is done becquse the `rpc` macro of the RpcServer is built to 
# catch exceptions rather than parse the result object directly
template unpackEngineResult[T](res: EngineResult[T]): T =
  res.valueOr:
    raise newException(ValueError, $error.errType & " -> " & error.errMsg)

proc injectEngineFrontend*(server: JsonRpcServer, frontend: EthApiFrontend) =
  server.getServer().rpc("eth_blockNumber", EthJson) do() -> uint64:
    unpackEngineResult(await frontend.eth_blockNumber())

  server.getServer().rpc("eth_getBalance", EthJson) do(
    address: Address, quantityTag: BlockTag
  ) -> UInt256:
    unpackEngineResult(await frontend.eth_getBalance(address, quantityTag))

  server.getServer().rpc("eth_getStorageAt", EthJson) do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> FixedBytes[32]:
    unpackEngineResult(await frontend.eth_getStorageAt(address, slot, quantityTag))

  server.getServer().rpc("eth_getTransactionCount", EthJson) do(
    address: Address, quantityTag: BlockTag
  ) -> Quantity:
    unpackEngineResult(await frontend.eth_getTransactionCount(address, quantityTag))

  server.getServer().rpc("eth_getCode", EthJson) do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    unpackEngineResult(await frontend.eth_getCode(address, quantityTag))

  server.getServer().rpc("eth_getBlockByHash", EthJson) do(
    blockHash: Hash32, fullTransactions: bool
  ) -> BlockObject:
    unpackEngineResult(await frontend.eth_getBlockByHash(blockHash, fullTransactions))

  server.getServer().rpc("eth_getBlockByNumber", EthJson) do(
    blockTag: BlockTag, fullTransactions: bool
  ) -> BlockObject:
    unpackEngineResult(await frontend.eth_getBlockByNumber(blockTag, fullTransactions))

  server.getServer().rpc("eth_getUncleCountByBlockNumber", EthJson) do(
    blockTag: BlockTag
  ) -> Quantity:
    unpackEngineResult(await frontend.eth_getUncleCountByBlockNumber(blockTag))

  server.getServer().rpc("eth_getUncleCountByBlockHash", EthJson) do(
    blockHash: Hash32
  ) -> Quantity:
    unpackEngineResult(await frontend.eth_getUncleCountByBlockHash(blockHash))

  server.getServer().rpc("eth_getBlockTransactionCountByNumber", EthJson) do(
    blockTag: BlockTag
  ) -> Quantity:
    unpackEngineResult(await frontend.eth_getBlockTransactionCountByNumber(blockTag))

  server.getServer().rpc("eth_getBlockTransactionCountByHash", EthJson) do(
    blockHash: Hash32
  ) -> Quantity:
    unpackEngineResult(await frontend.eth_getBlockTransactionCountByHash(blockHash))

  server.getServer().rpc("eth_getTransactionByBlockNumberAndIndex", EthJson) do(
    blockTag: BlockTag, index: Quantity
  ) -> TransactionObject:
    unpackEngineResult(
      await frontend.eth_getTransactionByBlockNumberAndIndex(blockTag, index)
    )

  server.getServer().rpc("eth_getTransactionByBlockHashAndIndex", EthJson) do(
    blockHash: Hash32, index: Quantity
  ) -> TransactionObject:
    unpackEngineResult(
      await frontend.eth_getTransactionByBlockHashAndIndex(blockHash, index)
    )

  server.getServer().rpc("eth_call", EthJson) do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> seq[byte]:
    unpackEngineResult(
      await frontend.eth_call(tx, blockTag, optimisticStateFetch.get(true))
    )

  server.getServer().rpc("eth_createAccessList", EthJson) do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> AccessListResult:
    unpackEngineResult(
      await frontend.eth_createAccessList(tx, blockTag, optimisticStateFetch.get(true))
    )

  server.getServer().rpc("eth_estimateGas", EthJson) do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> Quantity:
    unpackEngineResult(
      await frontend.eth_estimateGas(tx, blockTag, optimisticStateFetch.get(true))
    )

  server.getServer().rpc("eth_getTransactionByHash", EthJson) do(
    txHash: Hash32
  ) -> TransactionObject:
    unpackEngineResult(await frontend.eth_getTransactionByHash(txHash))

  server.getServer().rpc("eth_getBlockReceipts", EthJson) do(
    blockTag: BlockTag
  ) -> Opt[seq[ReceiptObject]]:
    unpackEngineResult(await frontend.eth_getBlockReceipts(blockTag))

  server.getServer().rpc("eth_getTransactionReceipt", EthJson) do(
    txHash: Hash32
  ) -> ReceiptObject:
    unpackEngineResult(await frontend.eth_getTransactionReceipt(txHash))

  server.getServer().rpc("eth_getLogs", EthJson) do(
    filterOptions: FilterOptions
  ) -> seq[LogObject]:
    unpackEngineResult(await frontend.eth_getLogs(filterOptions))

  server.getServer().rpc("eth_newFilter", EthJson) do(filterOptions: FilterOptions) -> string:
    unpackEngineResult(await frontend.eth_newFilter(filterOptions))

  server.getServer().rpc("eth_uninstallFilter", EthJson) do(filterId: string) -> bool:
    unpackEngineResult(await frontend.eth_uninstallFilter(filterId))

  server.getServer().rpc("eth_getFilterLogs", EthJson) do(filterId: string) -> seq[LogObject]:
    unpackEngineResult(await frontend.eth_getFilterLogs(filterId))

  server.getServer().rpc("eth_getFilterChanges", EthJson) do(filterId: string) -> seq[LogObject]:
    unpackEngineResult(await frontend.eth_getFilterChanges(filterId))

  server.getServer().rpc("eth_blobBaseFee", EthJson) do() -> UInt256:
    unpackEngineResult(await frontend.eth_blobBaseFee())

  server.getServer().rpc("eth_gasPrice", EthJson) do() -> Quantity:
    unpackEngineResult(await frontend.eth_gasPrice())

  server.getServer().rpc("eth_maxPriorityFeePerGas", EthJson) do() -> Quantity:
    unpackEngineResult(await frontend.eth_maxPriorityFeePerGas())

  server.getServer().rpc("eth_feeHistory", EthJson) do(
    blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
  ) -> FeeHistoryResult:
    unpackEngineResult(
      await frontend.eth_feeHistory(blockCount, newestBlock, rewardPercentiles)
    )

  server.getServer().rpc("eth_sendRawTransaction", EthJson) do(txBytes: seq[byte]) -> Hash32:
    unpackEngineResult(await frontend.eth_sendRawTransaction(txBytes))

proc stop*(server: JsonRpcServer) {.async: (raises: []).} =
  case server.kind
  of Http:
    await server.httpServer.closeWait()
  of WebSocket:
    await server.wsServer.closeWait()
