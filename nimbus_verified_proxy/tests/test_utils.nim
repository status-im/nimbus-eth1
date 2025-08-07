# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push gcsafe, raises: [].}

import
  stint,
  json_rpc/[rpcclient, rpcproxy, rpcserver, jsonmarshal],
  stew/io2,
  web3/eth_api_types,
  eth/common/eth_types_rlp,
  ../../execution_chain/rpc/cors,
  ../../execution_chain/common/common,
  ../types,
  ../rpc/evm,
  ../rpc/rpc_eth_api,
  ../nimbus_verified_proxy_conf,
  ../header_store,
  ./test_api_backend

proc getBlockFromJson*(filepath: string): BlockObject {.raises: [SerializationError].} =
  var blkBytes = readAllBytes(filepath)
  let blk = JrpcConv.decode(blkBytes.get, BlockObject)
  return blk

proc getReceiptsFromJson*(
    filepath: string
): seq[ReceiptObject] {.raises: [SerializationError].} =
  var rxBytes = readAllBytes(filepath)
  let rxs = JrpcConv.decode(rxBytes.get, seq[ReceiptObject])
  return rxs

proc getLogsFromJson*(
    filepath: string
): seq[LogObject] {.raises: [SerializationError].} =
  var logBytes = readAllBytes(filepath)
  let logs = JrpcConv.decode(logBytes.get, seq[LogObject])
  return logs

template `==`*(b1: BlockObject, b2: BlockObject): bool =
  JrpcConv.encode(b1).JsonString == JrpcConv.encode(b2).JsonString

template `==`*(tx1: TransactionObject, tx2: TransactionObject): bool =
  JrpcConv.encode(tx1).JsonString == JrpcConv.encode(tx2).JsonString

template `==`*(rx1: ReceiptObject, rx2: ReceiptObject): bool =
  JrpcConv.encode(rx1).JsonString == JrpcConv.encode(rx2).JsonString

template `==`*(rxs1: seq[ReceiptObject], rxs2: seq[ReceiptObject]): bool =
  JrpcConv.encode(rxs1).JsonString == JrpcConv.encode(rxs2).JsonString

template `==`*(logs1: seq[LogObject], logs2: seq[LogObject]): bool =
  JrpcConv.encode(logs1).JsonString == JrpcConv.encode(logs2).JsonString

proc startTestSetup*(
    testState: TestApiState, headerCacheLen: int, maxBlockWalk: uint64, port: int = 8545
): VerifiedRpcProxy {.raises: [CatchableError].} =
  let
    chainId = 1.u256
    networkId = 1.u256
    authHooks = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    web3Url = Web3Url(kind: Web3UrlKind.HttpUrl, web3Url: "http://127.0.0.1:" & $port)
    clientConfig = web3Url.asClientConfig()
    rpcProxy = RpcProxy.new([initTAddress("127.0.0.1", port)], clientConfig, authHooks)
    headerStore = HeaderStore.new(headerCacheLen)

    vp = VerifiedRpcProxy.init(rpcProxy, headerStore, chainId, maxBlockWalk)

  vp.evm = AsyncEvm.init(vp.toAsyncEvmStateBackend(), networkId)
  vp.rpcClient = initTestApiBackend(testState)
  vp.installEthApiHandlers()

  waitFor vp.proxy.start()
  waitFor vp.verifyChaindId()
  return vp

proc stopTestSetup*(vp: VerifiedRpcProxy) {.raises: [CatchableError].} =
  waitFor vp.proxy.stop()
