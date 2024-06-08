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
  eth/p2p as eth_p2p,
  eth/trie/trie_defs,
  stew/[byteutils],
  json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/[
    config,
    constants,
    transaction,
    db/ledger,
    core/chain,
    core/tx_pool,
    rpc,
    sync/protocol,
    beacon/beacon_engine,
    common
  ],
  ../../../tests/test_helpers,
  ../../../tools/evmstate/helpers

type
  TestEnv* = ref object
    conf*: NimbusConf
    ctx: EthContext
    ethNode: EthereumNode
    com: CommonRef
    chainRef: ChainRef
    rpcServer: RpcHttpServer
    rpcClient*: RpcHttpClient

proc genesisHeader(node: JsonNode): BlockHeader =
  let genesisRLP = hexToSeqByte(node["genesisRLP"].getStr)
  rlp.decode(genesisRLP, EthBlock).header

proc setupELClient*(t: TestEnv, conf: ChainConfig, node: JsonNode) =
  let memDB = newCoreDbRef DefaultDbMemory
  t.ctx  = newEthContext()
  t.ethNode = setupEthNode(t.conf, t.ctx, eth)
  t.com = CommonRef.new(
      memDB,
      conf
    )
  t.chainRef = newChain(t.com, extraValidation = true)
  let
    stateDB = LedgerRef.init(memDB, emptyRlpHash)
    genesisHeader = node.genesisHeader

  setupStateDB(node["pre"], stateDB)
  stateDB.persist()

  doAssert stateDB.rootHash == genesisHeader.stateRoot

  t.com.db.persistHeaderToDb(genesisHeader,
    t.com.consensus == ConsensusType.POS)
  doAssert(t.com.db.getCanonicalHead().blockHash == genesisHeader.blockHash)

  let txPool  = TxPoolRef.new(t.com)
  t.rpcServer = newRpcHttpServer(["127.0.0.1:8545"])

  let beaconEngine = BeaconEngineRef.new(txPool, t.chainRef)
  let oracle = Oracle.new(t.com)
  setupEthRpc(t.ethNode, t.ctx, t.com, txPool, oracle, t.rpcServer)
  setupEngineAPI(beaconEngine, t.rpcServer)

  t.rpcServer.start()

  t.rpcClient = newRpcHttpClient()
  waitFor t.rpcClient.connect("127.0.0.1", 8545.Port, false)

proc stopELClient*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.rpcServer.closeWait()
