# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json],
  stew/[byteutils],
  json_rpc/[rpcserver, rpcclient],
  ../../../execution_chain/[
    constants,
    transaction,
    db/ledger,
    core/chain,
    core/tx_pool,
    rpc,
    beacon/beacon_engine,
    common
  ],
  ../../../tools/evmstate/helpers

type
  TestEnv* = ref object
    chain     : ForkedChainRef
    rpcServer : RpcHttpServer
    rpcClient*: RpcHttpClient

proc genesisHeader(node: JsonNode): Header =
  let genesisRLP = hexToSeqByte(node["genesisRLP"].getStr)
  rlp.decode(genesisRLP, Block).header

proc initializeDb(memDB: CoreDbRef, node: JsonNode): Hash32 =
  let
    genesisHeader = node.genesisHeader
    ledger = LedgerRef.init(memDB.baseTxFrame())

  ledger.txFrame.persistHeaderAndSetHead(genesisHeader).expect("persistHeader no error")
  setupLedger(node["pre"], ledger)
  ledger.persist()
  doAssert ledger.getStateRoot == genesisHeader.stateRoot

  genesisHeader.blockHash

proc setupELClient*(conf: ChainConfig, taskPool: Taskpool, node: JsonNode): TestEnv =
  let
    memDB = newCoreDbRef DefaultDbMemory
    genesisHash = initializeDb(memDB, node)
    com = CommonRef.new(memDB, taskPool, conf)
    chain = ForkedChainRef.init(com)

  let headHash = chain.latestHash
  doAssert(headHash == genesisHash)

  let
    txPool  = TxPoolRef.new(chain)
    beaconEngine = BeaconEngineRef.new(txPool)
    serverApi = newServerAPI(txPool)
    rpcServer = newRpcHttpServer(["127.0.0.1:0"])
    rpcClient = newRpcHttpClient()

  setupServerAPI(serverApi, rpcServer, newEthContext())
  setupEngineAPI(beaconEngine, rpcServer)

  rpcServer.start()
  waitFor rpcClient.connect("127.0.0.1", rpcServer.localAddress[0].port, false)

  TestEnv(
    chain: chain,
    rpcServer: rpcServer,
    rpcClient: rpcClient,
  )

proc stopELClient*(env: TestEnv) =
  waitFor env.rpcClient.close()
  waitFor env.rpcServer.closeWait()
