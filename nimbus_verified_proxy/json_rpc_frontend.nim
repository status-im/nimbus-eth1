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

type
  JsonRpcFrontend* = ref object
    case kind*: ClientKind #we reuse clientKind for servers also
    of Http:
      httpServer: RpcHttpServer
    of WebSocket:
      wsServer: RpcWebSocketServer

proc init*(T: type JsonRpcFrontend, url: Web3Url): JsonRpcFrontend {.raises: [JsonRpcError, ValueError, TransportAddressError]} =
  var frontend: JsonRpcFrontend

  let
    auth = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    parsedUrl = parseUri(url.web3Url)
    hostname = 
      if parsedUrl.hostname == "":
        "127.0.0.1"
      else:
        parsedUrl.hostname
    port = 
      if parsedUrl.port == "":
        8545
      else:
        parseInt(parsedUrl.port)
    listenAddress = initTAddress(hostname, port)

  if url.kind == HttpUrl: 
    frontend = JsonRpcFrontend(
      kind: Http,
      httpServer: newRpcHttpServer([listenAddress], RpcRouter.init(), auth),
    )
  elif url.kind == WsUrl:
    frontend = JsonRpcFrontend(
      kind: WebSocket,
      wsServer: newRpcWebSocketServer(listenAddress),
    )

    frontend.wsServer.router = RpcRouter.init()

  frontend

proc start*(frontend: JsonRpcFrontend): Result[void, string] = 

  try:
    if frontend.kind == Http:
      frontend.httpServer.start()
    elif frontend.kind == WebSocket:
      frontend.wsServer.start()
  except CatchableError as e:
    return err(e.msg)

  ok()

proc getServer(frontend: JsonRpcFrontend): RpcServer =
  case frontend.kind:
  of Http:
    frontend.httpServer
  of WebSocket:
    frontend.wsServer

proc injectEngineFrontend*(frontend: JsonRpcFrontend, engineFrontend: EthApiFrontend) =
  frontend.getServer().rpc("eth_blockNumber") do() -> uint64:
    await engineFrontend.eth_blockNumber()

  frontend.getServer().rpc("eth_getBalance") do(address: Address, quantityTag: BlockTag) -> UInt256:
    await engineFrontend.eth_getBalance(address, quantityTag)

  frontend.getServer().rpc("eth_getStorageAt") do(address: Address, slot: UInt256, quantityTag: BlockTag) -> FixedBytes[32]:
    await engineFrontend.eth_getStorageAt(address, slot, quantityTag)

  frontend.getServer().rpc("eth_getTransactionCount") do(address: Address, quantityTag: BlockTag) -> Quantity:
    await engineFrontend.eth_getTransactionCount(address, quantityTag)

  frontend.getServer().rpc("eth_getCode") do(address: Address, quantityTag: BlockTag) -> seq[byte]:
    await engineFrontend.eth_getCode(address, quantityTag)

  frontend.getServer().rpc("eth_getBlockByHash") do(blockHash: Hash32, fullTransactions: bool) -> BlockObject:
    await engineFrontend.eth_getBlockByHash(blockHash, fullTransactions)

  frontend.getServer().rpc("eth_getBlockByNumber") do(blockTag: BlockTag, fullTransactions: bool) -> BlockObject:
    await engineFrontend.eth_getBlockByNumber(blockTag, fullTransactions)

  frontend.getServer().rpc("eth_getUncleCountByBlockNumber") do(blockTag: BlockTag) -> Quantity:
    await engineFrontend.eth_getUncleCountByBlockNumber(blockTag)

  frontend.getServer().rpc("eth_getUncleCountByBlockHash") do(blockHash: Hash32) -> Quantity:
    await engineFrontend.eth_getUncleCountByBlockHash(blockHash)

  frontend.getServer().rpc("eth_getBlockTransactionCountByNumber") do(blockTag: BlockTag) -> Quantity:
    await engineFrontend.eth_getBlockTransactionCountByNumber(blockTag)

  frontend.getServer().rpc("eth_getBlockTransactionCountByHash") do(blockHash: Hash32) -> Quantity:
    await engineFrontend.eth_getBlockTransactionCountByHash(blockHash)

  frontend.getServer().rpc("eth_getTransactionByBlockNumberAndIndex") do(blockTag: BlockTag, index: Quantity) -> TransactionObject:
    await engineFrontend.eth_getTransactionByBlockNumberAndIndex(blockTag, index)

  frontend.getServer().rpc("eth_getTransactionByBlockHashAndIndex") do(blockHash: Hash32, index: Quantity) -> TransactionObject:
    await engineFrontend.eth_getTransactionByBlockHashAndIndex(blockHash, index)

  frontend.getServer().rpc("eth_call") do(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]) -> seq[byte]:
    await engineFrontend.eth_call(tx, blockTag, optimisticStateFetch)

  frontend.getServer().rpc("eth_createAccessList") do(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]) -> AccessListResult:
    await engineFrontend.eth_createAccessList(tx, blockTag, optimisticStateFetch)

  frontend.getServer().rpc("eth_estimateGas") do(tx: TransactionArgs, blockTag: BlockTag, optimisticStateFetch: Opt[bool]) -> Quantity:
    await engineFrontend.eth_estimateGas(tx, blockTag, optimisticStateFetch)

  frontend.getServer().rpc("eth_getTransactionByHash") do(txHash: Hash32) -> TransactionObject:
    await engineFrontend.eth_getTransactionByHash(txHash)

  frontend.getServer().rpc("eth_getBlockReceipts") do(blockTag: BlockTag) -> Opt[seq[ReceiptObject]]:
    await engineFrontend.eth_getBlockReceipts(blockTag)

  frontend.getServer().rpc("eth_getTransactionReceipt") do(txHash: Hash32) -> ReceiptObject:
    await engineFrontend.eth_getTransactionReceipt(txHash)

  frontend.getServer().rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[LogObject]:
    await engineFrontend.eth_getLogs(filterOptions)

  frontend.getServer().rpc("eth_newFilter") do(filterOptions: FilterOptions) -> string:
    await engineFrontend.eth_newFilter(filterOptions)

  frontend.getServer().rpc("eth_uninstallFilter") do(filterId: string) -> bool:
    await engineFrontend.eth_uninstallFilter(filterId)

  frontend.getServer().rpc("eth_getFilterLogs") do(filterId: string) -> seq[LogObject]:
    await engineFrontend.eth_getFilterLogs(filterId)

  frontend.getServer().rpc("eth_getFilterChanges") do(filterId: string) -> seq[LogObject]:
    await engineFrontend.eth_getFilterChanges(filterId)

  frontend.getServer().rpc("eth_blobBaseFee") do() -> UInt256:
    await engineFrontend.eth_blobBaseFee()

  frontend.getServer().rpc("eth_gasPrice") do() -> Quantity:
    await engineFrontend.eth_gasPrice()

  frontend.getServer().rpc("eth_maxPriorityFeePerGas") do() -> Quantity:
    await engineFrontend.eth_maxPriorityFeePerGas()

proc stop*(frontend: JsonRpcFrontend) {.async.} = 
  case frontend.kind:
  of Http:
    await frontend.httpServer.closeWait()
  of WebSocket:
    await frontend.wsServer.closeWait()
