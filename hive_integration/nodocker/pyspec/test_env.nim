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
    db/accounts_cache,
    core/sealer,
    core/chain,
    core/tx_pool,
    rpc,
    sync/protocol,
    rpc/merge/merger,
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
    sealingEngine: SealingEngineRef
    rpcClient*: RpcHttpClient

const
  engineSigner = hexToByteArray[20]("0x658bdf435d810c91414ec09147daa6db62406379")

proc genesisHeader(node: JsonNode): BlockHeader =
  let genesisRLP = hexToSeqByte(node["genesisRLP"].getStr)
  rlp.decode(genesisRLP, EthBlock).header

proc setupELClient*(t: TestEnv, conf: ChainConfig, node: JsonNode) =
  let memDB = newCoreDbRef LegacyDbMemory
  t.ctx  = newEthContext()
  t.ethNode = setupEthNode(t.conf, t.ctx, eth)
  t.com = CommonRef.new(
      memDB,
      conf,
      t.conf.pruneMode == PruneMode.Full
    )
  t.chainRef = newChain(t.com)
  let
    stateDB = AccountsCache.init(memDB, emptyRlpHash, t.conf.pruneMode == PruneMode.Full)
    genesisHeader = node.genesisHeader

  setupStateDB(node["pre"], stateDB)
  stateDB.persist()

  doAssert stateDB.rootHash == genesisHeader.stateRoot

  discard t.com.db.persistHeaderToDb(genesisHeader,
    t.com.consensus == ConsensusType.POS)
  doAssert(t.com.db.getCanonicalHead().blockHash == genesisHeader.blockHash)

  let txPool  = TxPoolRef.new(t.com, engineSigner)
  t.rpcServer = newRpcHttpServer(["127.0.0.1:8545"])
  t.sealingEngine = SealingEngineRef.new(
    t.chainRef, t.ctx, engineSigner,
    txPool, EngineStopped
  )

  let merger = MergerRef.new(t.com.db)
  setupEthRpc(t.ethNode, t.ctx, t.com, txPool, t.rpcServer)
  setupEngineAPI(t.sealingEngine, t.rpcServer, merger)
  #setupDebugRpc(t.com, t.rpcServer)

  t.rpcServer.start()

  t.rpcClient = newRpcHttpClient()
  waitFor t.rpcClient.connect("127.0.0.1", 8545.Port, false)

proc stopELClient*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.sealingEngine.stop()
  waitFor t.rpcServer.closeWait()
