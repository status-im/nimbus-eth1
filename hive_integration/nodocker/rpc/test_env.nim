# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, net],
  eth/p2p as ethp2p,
  stew/results,
  chronos, json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/sync/protocol,
  ../../../nimbus/common,
  ../../../nimbus/config,
  ../../../nimbus/rpc,
  ../../../nimbus/utils/utils,
  ../../../nimbus/core/[chain, tx_pool],
  ../../../tests/test_helpers,
  ./vault

type
  StopServerProc = proc(srv: RpcServer)

  TestEnv* = ref object
    vault*: Vault
    rpcClient*: RpcClient
    rpcServer: RpcServer
    stopServer: StopServerProc

const
  initPath = "hive_integration" / "nodocker" / "rpc" / "init"
  gasPrice* = 30.gwei
  chainID*  = ChainID(7)

proc manageAccounts(ctx: EthContext, conf: NimbusConf) =
  if string(conf.importKey).len > 0:
    let res = ctx.am.importPrivateKey(string conf.importKey)
    if res.isErr:
      echo res.error()
      quit(QuitFailure)

proc setupRpcServer(ctx: EthContext, com: CommonRef,
                    ethNode: EthereumNode, txPool: TxPoolRef,
                    conf: NimbusConf): RpcServer  =
  let rpcServer = newRpcHttpServer([initTAddress(conf.httpAddress, conf.httpPort)])
  let oracle = Oracle.new(com)
  setupCommonRpc(ethNode, conf, rpcServer)
  setupEthRpc(ethNode, ctx, com, txPool, oracle, rpcServer)

  rpcServer.start()
  rpcServer

proc stopRpcHttpServer(srv: RpcServer) =
  let rpcServer = RpcHttpServer(srv)
  waitFor rpcServer.stop()
  waitFor rpcServer.closeWait()

proc setupEnv*(): TestEnv =
  let conf = makeConfig(@[
    "--chaindb:archive",
    # "--nat:extip:0.0.0.0",
    "--network:7",
    "--import-key:" & initPath / "private-key",
    "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
    "--custom-network:" & initPath / "genesis.json",
    "--rpc",
    "--rpc-api:eth,debug",
    # "--http-address:0.0.0.0",
    "--http-port:8545",
  ])

  let
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    com     = CommonRef.new(newCoreDbRef DefaultDbMemory,
      conf.networkId,
      conf.networkParams
    )

  manageAccounts(ethCtx, conf)
  com.initializeEmptyDb()

  let chainRef = newChain(com)
  let txPool = TxPoolRef.new(com, ZERO_ADDRESS)

  # txPool must be informed of active head
  # so it can know the latest account state
  let head = com.db.getCanonicalHead()
  doAssert txPool.smartHead(head)

  let rpcServer = setupRpcServer(ethCtx, com, ethNode, txPool, conf)
  let rpcClient = newRpcHttpClient()
  waitFor rpcClient.connect("127.0.0.1", Port(8545), false)
  let stopServer = stopRpcHttpServer

  let t = TestEnv(
    rpcClient: rpcClient,
    rpcServer: rpcServer,
    vault : newVault(chainID, gasPrice, rpcClient),
    stopServer: stopServer
  )

  result = t

proc stopEnv*(t: TestEnv) =
  waitFor t.rpcClient.close()
  t.stopServer(t.rpcServer)
