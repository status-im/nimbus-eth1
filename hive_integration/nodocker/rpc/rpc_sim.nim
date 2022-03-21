# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/os, asynctest,
  eth/[trie/db],
  eth/p2p as ethP2p,
  stew/shims/net as stewNet,
  stew/results,
  chronos, json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/db/db_chain,
  ../../../nimbus/p2p/protocol_ethxx,
  ../../../nimbus/[config, context, genesis],
  ../../../nimbus/rpc/[common, p2p, debug],
  ../../../tests/test_helpers,
  "."/[callsigs, ethclient, vault, client]

const
  initPath = "hive_integration" / "nodocker" / "rpc" / "init"

proc manageAccounts(ctx: EthContext, conf: NimbusConf) =
  if string(conf.importKey).len > 0:
    let res = ctx.am.importPrivateKey(string conf.importKey)
    if res.isErr:
      echo res.error()
      quit(QuitFailure)

proc setupRpcServer(ctx: EthContext, chainDB: BaseChainDB, ethNode: EthereumNode, conf: NimbusConf): RpcServer  =
  let rpcServer = newRpcHttpServer([initTAddress(conf.rpcAddress, conf.rpcPort)])
  setupCommonRpc(ethNode, conf, rpcServer)
  setupEthRpc(ethNode, ctx, chainDB, rpcServer)

  rpcServer.start()
  rpcServer

proc setupWsRpcServer(ctx: EthContext, chainDB: BaseChainDB, ethNode: EthereumNode, conf: NimbusConf): RpcServer  =
  let rpcServer = newRpcWebSocketServer(initTAddress(conf.wsAddress, conf.wsPort))
  setupCommonRpc(ethNode, conf, rpcServer)
  setupEthRpc(ethNode, ctx, chainDB, rpcServer)

  rpcServer.start()
  rpcServer

proc runRpcTest() =
  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", Port(8545), false)

  let testEnv = TestEnv(
    client: client,
    vault : newVault(chainID, gasPrice, client)
  )

  suite "JSON RPC Test Over HTTP":
    test "env test":
      check await envTest(testEnv)
  
proc main() =
  let conf = makeConfig(@[
    "--prune-mode:archive",
    # "--nat:extip:0.0.0.0",
    "--network:7",
    "--import-key:" & initPath / "private-key",
    "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
    "--custom-network:" & initPath / "genesis.json",
    "--rpc",
    "--rpc-api:eth,debug",
    # "--rpc-address:0.0.0.0",
    "--rpc-port:8545",
    "--ws",
    "--ws-api:eth,debug",
    # "--ws-address:0.0.0.0",
    "--ws-port:8546"
  ])

  let
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    chainDB = newBaseChainDB(newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )

  chainDB.populateProgress()
  chainDB.initializeEmptyDb()
  let rpcServer = setupRpcServer(ethCtx, chainDB, ethNode, conf)
  runRpcTest()

main()
