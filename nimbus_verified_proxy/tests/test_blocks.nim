# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stint,
  web3/[eth_api_types, eth_api],
  stew/io2,
  json_rpc/[rpcclient, rpcproxy, rpcserver, jsonmarshal],
  eth/common/eth_types_rlp,
  ../../execution_chain/rpc/cors,
  ../../execution_chain/common/common,
  ../types,
  ../rpc/evm,
  ../rpc/rpc_eth_api,
  ../rpc/blocks,
  ../nimbus_verified_proxy_conf,
  ../header_store,
  ./test_api_backend

proc startVerifiedProxy(
    testState: TestApiState, headerCacheLen: int, maxBlockWalk: uint64
): VerifiedRpcProxy =
  let
    chainId = 1.u256
    networkId = 1.u256
    authHooks = @[httpCors(@[])] # TODO: for now we serve all cross origin requests
    web3Url = Web3Url(kind: Web3UrlKind.HttpUrl, web3Url: "http://127.0.0.1:8545")
    clientConfig = web3Url.asClientConfig()
    rpcProxy = RpcProxy.new([initTAddress("127.0.0.1", 8545)], clientConfig, authHooks)
    headerStore = HeaderStore.new(headerCacheLen)

    verifiedProxy = VerifiedRpcProxy.init(rpcProxy, headerStore, chainId, maxBlockWalk)

  verifiedProxy.evm = AsyncEvm.init(verifiedProxy.toAsyncEvmStateBackend(), networkId)
  verifiedProxy.rpcClient = initTestApiBackend(testState)
  verifiedProxy.installEthApiHandlers()

  waitFor rpcProxy.start()
  waitFor verifiedProxy.verifyChaindId()
  return verifiedProxy

proc stopVerifiedProxy(vp: VerifiedRpcProxy) =
  waitFor vp.proxy.stop()

proc getBlockFromJson(filepath: string): BlockObject =
  var blkBytes = readAllBytes(filepath)
  let blk = JrpcConv.decode(blkBytes.get, BlockObject)
  return blk

suite "rpc blocks":
  test "get block by hash - correct block - completeness check":
    let
      testState = TestApiState.init(1.u256)
      vp = startVerifiedProxy(testState, 1, 1)
      blk = getBlockFromJson("nimbus_verified_proxy/tests/block.json")

    testState.loadFullBlock(blk.hash, blk)
    let status = vp.headerStore.add(convHeader(blk), blk.hash).valueOr:
      raise newException(ValueError, error)

    # reuse verified proxy's internal client. Conveniently it is looped back to the proxy server
    let verifiedBlk = waitFor vp.proxy.getClient().eth_getBlockByHash(blk.hash, true)

    vp.stopVerifiedProxy()

    let
      blkStr = JrpcConv.encode(blk).JsonString
      verifiedBlkStr = JrpcConv.encode(verifiedBlk).JsonString

    check blkStr == verifiedBlkStr
