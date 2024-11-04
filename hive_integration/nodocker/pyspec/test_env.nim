# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ../../../nimbus/[
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

proc setupELClient*(conf: ChainConfig, node: JsonNode): TestEnv =
  let
    memDB = newCoreDbRef DefaultDbMemory
    genesisHeader = node.genesisHeader
    com = CommonRef.new(memDB, conf)
    stateDB = LedgerRef.init(memDB)
    chain = newForkedChain(com, genesisHeader)

  setupStateDB(node["pre"], stateDB)
  stateDB.persist()
  doAssert stateDB.getStateRoot == genesisHeader.stateRoot

  doAssert com.db.persistHeader(genesisHeader,
              com.proofOfStake(genesisHeader))
  doAssert(com.db.getCanonicalHead().blockHash ==
              genesisHeader.blockHash)

  let
    txPool  = TxPoolRef.new(com)
    beaconEngine = BeaconEngineRef.new(txPool, chain)
    serverApi = newServerAPI(chain, txPool)
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
