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
  server.getServer().rpc(EthJson):
    proc eth_blockNumber(): uint64 {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_blockNumber())

    proc eth_getBalance(address: Address, quantityTag: BlockTag): UInt256 {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getBalance(address, quantityTag))

    proc eth_getStorageAt(
      address: Address, slot: UInt256, quantityTag: BlockTag
    ): FixedBytes[32] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getStorageAt(address, slot, quantityTag))

    proc eth_getTransactionCount(
      address: Address, quantityTag: BlockTag
    ): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getTransactionCount(address, quantityTag))

    proc eth_getCode(address: Address, quantityTag: BlockTag): seq[byte] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getCode(address, quantityTag))

    proc eth_getBlockByHash(
      blockHash: Hash32, fullTransactions: bool
    ): BlockObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getBlockByHash(blockHash, fullTransactions))

    proc eth_getBlockByNumber(
      blockTag: BlockTag, fullTransactions: bool
    ): BlockObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_getBlockByNumber(blockTag, fullTransactions)
      )

    proc eth_getUncleCountByBlockNumber(blockTag: BlockTag): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getUncleCountByBlockNumber(blockTag))

    proc eth_getUncleCountByBlockHash(blockHash: Hash32): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getUncleCountByBlockHash(blockHash))

    proc eth_getBlockTransactionCountByNumber(blockTag: BlockTag): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getBlockTransactionCountByNumber(blockTag))

    proc eth_getBlockTransactionCountByHash(blockHash: Hash32): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getBlockTransactionCountByHash(blockHash))

    proc eth_getTransactionByBlockNumberAndIndex(
      blockTag: BlockTag, index: Quantity
    ): TransactionObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_getTransactionByBlockNumberAndIndex(blockTag, index)
      )

    proc eth_getTransactionByBlockHashAndIndex(
      blockHash: Hash32, index: Quantity
    ): TransactionObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_getTransactionByBlockHashAndIndex(blockHash, index)
      )

    proc eth_call(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
    ): seq[byte] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_call(tx, blockTag, optimisticStateFetch.get(true))
      )

    proc eth_createAccessList(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
    ): AccessListResult {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_createAccessList(
          tx, blockTag, optimisticStateFetch.get(true)
        )
      )

    proc eth_estimateGas(
      tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
    ): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_estimateGas(tx, blockTag, optimisticStateFetch.get(true))
      )

    proc eth_getTransactionByHash(txHash: Hash32): TransactionObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getTransactionByHash(txHash))

    proc eth_getBlockReceipts(blockTag: BlockTag): Opt[seq[ReceiptObject]] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getBlockReceipts(blockTag))

    proc eth_getTransactionReceipt(txHash: Hash32): ReceiptObject {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getTransactionReceipt(txHash))

    proc eth_getLogs(filterOptions: FilterOptions): seq[LogObject] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getLogs(filterOptions))

    proc eth_newFilter(filterOptions: FilterOptions): string {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_newFilter(filterOptions))

    proc eth_uninstallFilter(filterId: string): bool {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_uninstallFilter(filterId))

    proc eth_getFilterLogs(filterId: string): seq[LogObject] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getFilterLogs(filterId))

    proc eth_getFilterChanges(filterId: string): seq[LogObject] {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_getFilterChanges(filterId))

    proc eth_blobBaseFee(): UInt256 {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_blobBaseFee())

    proc eth_gasPrice(): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_gasPrice())

    proc eth_maxPriorityFeePerGas(): Quantity {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_maxPriorityFeePerGas())

    proc eth_feeHistory(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): FeeHistoryResult {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(
        await frontend.eth_feeHistory(blockCount, newestBlock, rewardPercentiles)
      )

    proc eth_sendRawTransaction(txBytes: seq[byte]): Hash32 {.async: (raises: [ValueError, CancelledError]).} =
      unpackEngineResult(await frontend.eth_sendRawTransaction(txBytes))

proc stop*(server: JsonRpcServer) {.async: (raises: []).} =
  case server.kind
  of Http:
    await server.httpServer.stop()
    await server.httpServer.closeWait()
  of WebSocket:
    server.wsServer.stop()
    await server.wsServer.closeWait()
