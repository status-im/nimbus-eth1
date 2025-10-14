# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
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

proc init*(
    T: type JsonRpcServer, url: Web3Url
): JsonRpcServer {.raises: [JsonRpcError, ValueError, TransportAddressError].} =
  let
    auth = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    parsedUrl = parseUri(url.web3Url)
    hostname = if parsedUrl.hostname == "": "127.0.0.1" else: parsedUrl.hostname
    port =
      if parsedUrl.port == "":
        8545
      else:
        parseInt(parsedUrl.port)
    listenAddress = initTAddress(hostname, port)

  case url.kind
  of HttpUrl:
    JsonRpcServer(
      kind: Http, httpServer: newRpcHttpServer([listenAddress], RpcRouter.init(), auth)
    )
  of WsUrl:
    let server =
      JsonRpcServer(kind: WebSocket, wsServer: newRpcWebSocketServer(listenAddress))

    server.wsServer.router = RpcRouter.init()
    server

func getServer(server: JsonRpcServer): RpcServer =
  case server.kind
  of Http: server.httpServer
  of WebSocket: server.wsServer

proc start*(server: JsonRpcServer): Result[void, string] =
  try:
    case server.kind
    of Http:
      server.httpServer.start()
    of WebSocket:
      server.wsServer.start()
  except CatchableError as e:
    return err(e.msg)

  ok()

proc injectEngineFrontend*(server: JsonRpcServer, frontend: EthApiFrontend) =
  server.getServer().rpc("eth_blockNumber") do() -> uint64:
    await frontend.eth_blockNumber()

  server.getServer().rpc("eth_getBalance") do(
    address: Address, quantityTag: BlockTag
  ) -> UInt256:
    await frontend.eth_getBalance(address, quantityTag)

  server.getServer().rpc("eth_getStorageAt") do(
    address: Address, slot: UInt256, quantityTag: BlockTag
  ) -> FixedBytes[32]:
    await frontend.eth_getStorageAt(address, slot, quantityTag)

  server.getServer().rpc("eth_getTransactionCount") do(
    address: Address, quantityTag: BlockTag
  ) -> Quantity:
    await frontend.eth_getTransactionCount(address, quantityTag)

  server.getServer().rpc("eth_getCode") do(
    address: Address, quantityTag: BlockTag
  ) -> seq[byte]:
    await frontend.eth_getCode(address, quantityTag)

  server.getServer().rpc("eth_getBlockByHash") do(
    blockHash: Hash32, fullTransactions: bool
  ) -> BlockObject:
    await frontend.eth_getBlockByHash(blockHash, fullTransactions)

  server.getServer().rpc("eth_getBlockByNumber") do(
    blockTag: BlockTag, fullTransactions: bool
  ) -> BlockObject:
    await frontend.eth_getBlockByNumber(blockTag, fullTransactions)

  server.getServer().rpc("eth_getUncleCountByBlockNumber") do(
    blockTag: BlockTag
  ) -> Quantity:
    await frontend.eth_getUncleCountByBlockNumber(blockTag)

  server.getServer().rpc("eth_getUncleCountByBlockHash") do(
    blockHash: Hash32
  ) -> Quantity:
    await frontend.eth_getUncleCountByBlockHash(blockHash)

  server.getServer().rpc("eth_getBlockTransactionCountByNumber") do(
    blockTag: BlockTag
  ) -> Quantity:
    await frontend.eth_getBlockTransactionCountByNumber(blockTag)

  server.getServer().rpc("eth_getBlockTransactionCountByHash") do(
    blockHash: Hash32
  ) -> Quantity:
    await frontend.eth_getBlockTransactionCountByHash(blockHash)

  server.getServer().rpc("eth_getTransactionByBlockNumberAndIndex") do(
    blockTag: BlockTag, index: Quantity
  ) -> TransactionObject:
    await frontend.eth_getTransactionByBlockNumberAndIndex(blockTag, index)

  server.getServer().rpc("eth_getTransactionByBlockHashAndIndex") do(
    blockHash: Hash32, index: Quantity
  ) -> TransactionObject:
    await frontend.eth_getTransactionByBlockHashAndIndex(blockHash, index)

  server.getServer().rpc("eth_call") do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> seq[byte]:
    await frontend.eth_call(tx, blockTag, optimisticStateFetch.get(true))

  server.getServer().rpc("eth_createAccessList") do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> AccessListResult:
    await frontend.eth_createAccessList(tx, blockTag, optimisticStateFetch.get(true))

  server.getServer().rpc("eth_estimateGas") do(
    tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]
  ) -> Quantity:
    await frontend.eth_estimateGas(tx, blockTag, optimisticStateFetch.get(true))

  server.getServer().rpc("eth_getTransactionByHash") do(
    txHash: Hash32
  ) -> TransactionObject:
    await frontend.eth_getTransactionByHash(txHash)

  server.getServer().rpc("eth_getBlockReceipts") do(
    blockTag: BlockTag
  ) -> Opt[seq[ReceiptObject]]:
    await frontend.eth_getBlockReceipts(blockTag)

  server.getServer().rpc("eth_getTransactionReceipt") do(
    txHash: Hash32
  ) -> ReceiptObject:
    await frontend.eth_getTransactionReceipt(txHash)

  server.getServer().rpc("eth_getLogs") do(
    filterOptions: FilterOptions
  ) -> seq[LogObject]:
    await frontend.eth_getLogs(filterOptions)

  server.getServer().rpc("eth_newFilter") do(filterOptions: FilterOptions) -> string:
    await frontend.eth_newFilter(filterOptions)

  server.getServer().rpc("eth_uninstallFilter") do(filterId: string) -> bool:
    await frontend.eth_uninstallFilter(filterId)

  server.getServer().rpc("eth_getFilterLogs") do(filterId: string) -> seq[LogObject]:
    await frontend.eth_getFilterLogs(filterId)

  server.getServer().rpc("eth_getFilterChanges") do(filterId: string) -> seq[LogObject]:
    await frontend.eth_getFilterChanges(filterId)

  server.getServer().rpc("eth_blobBaseFee") do() -> UInt256:
    await frontend.eth_blobBaseFee()

  server.getServer().rpc("eth_gasPrice") do() -> Quantity:
    await frontend.eth_gasPrice()

  server.getServer().rpc("eth_maxPriorityFeePerGas") do() -> Quantity:
    await frontend.eth_maxPriorityFeePerGas()

proc stop*(server: JsonRpcServer) {.async: (raises: [CancelledError]).} =
  try:
    case server.kind
    of Http:
      await server.httpServer.closeWait()
    of WebSocket:
      await server.wsServer.closeWait()
  except CatchableError as e:
    raise newException(CancelledError, e.msg)
