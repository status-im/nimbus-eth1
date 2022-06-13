import
  std/[os, options, json, times, math],
  eth/[common, keys],
  eth/trie/db,
  eth/p2p as eth_p2p,
  stew/[results, byteutils],
  stint,
  json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/[
    config,
    genesis,
    context,
    constants,
    transaction,
    utils,
    sealer,
    p2p/chain,
    db/db_chain,
    rpc/p2p,
    rpc/engine_api,
    rpc/debug,
    sync/protocol,
    utils/tx_pool
  ],
  ../../../tests/test_helpers,
  "."/[clmock, engine_client]

import web3/engine_api_types
from web3/ethtypes as web3types import nil

export
  common, engine_api_types, times,
  options, results, constants, utils,
  TypedTransaction, clmock, engine_client

type
  EthBlockHeader* = common.BlockHeader

  TestEnv* = ref object
    conf: NimbusConf
    ctx: EthContext
    ethNode: EthereumNode
    chainDB: BaseChainDB
    chainRef: Chain
    rpcServer: RpcSocketServer
    sealingEngine: SealingEngineRef
    rpcClient*: RpcSocketClient
    gHeader*: EthBlockHeader
    ttd*: DifficultyInt
    clMock*: CLMocker
    nonce: uint64
    vaultKey*: PrivateKey

  Web3BlockHash* = web3types.BlockHash
  Web3Address* = web3types.Address
  Web3Bloom* = web3types.FixedBytes[256]
  Web3Quantity* = web3types.Quantity
  Web3PrevRandao* = web3types.FixedBytes[32]
  Web3ExtraData* = web3types.DynamicBytes[0, 32]

const
  baseFolder  = "hive_integration" / "nodocker" / "engine"
  genesisFile = baseFolder / "genesis.json"
  sealerKey   = baseFolder / "sealer.key"

  # This is the account that sends vault funding transactions.
  vaultAccountAddr* = hexToByteArray[20]("0xcf49fda3be353c69b41ed96333cd24302da4556f")
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"

proc setupELClient*(t: TestEnv) =
  t.ctx  = newEthContext()
  let res = t.ctx.am.importPrivateKey(sealerKey)
  if res.isErr:
    echo res.error()
    quit(QuitFailure)

  t.ethNode = setupEthNode(t.conf, t.ctx, eth)
  t.chainDB = newBaseChainDB(
      newMemoryDb(),
      t.conf.pruneMode == PruneMode.Full,
      t.conf.networkId,
      t.conf.networkParams
    )
  t.chainRef = newChain(t.chainDB)

  initializeEmptyDb(t.chainDB)
  let txPool = TxPoolRef.new(t.chainDB, t.conf.engineSigner)

  t.rpcServer = newRpcSocketServer(["localhost:" & $t.conf.rpcPort])
  t.sealingEngine = SealingEngineRef.new(
    t.chainRef, t.ctx, t.conf.engineSigner,
    txPool, EngineStopped
  )

  setupEthRpc(t.ethNode, t.ctx, t.chainDB, txPool, t.rpcServer)
  setupEngineAPI(t.sealingEngine, t.rpcServer)
  setupDebugRpc(t.chainDB, t.rpcServer)

  t.sealingEngine.start()
  t.rpcServer.start()

  t.rpcClient = newRpcSocketClient()
  waitFor t.rpcClient.connect("localhost", t.conf.rpcPort)
  t.gHeader = toGenesisHeader(t.conf.networkParams)

  let kRes = PrivateKey.fromHex(vaultKeyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  t.vaultKey = kRes.get

proc setupELClient*(): TestEnv =
  result = TestEnv(
    conf: makeConfig(@["--engine-signer:658bdf435d810c91414ec09147daa6db62406379", "--custom-network:" & genesisFile])
  )
  setupELClient(result)

proc stopELClient*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.sealingEngine.stop()
  t.rpcServer.stop()
  waitFor t.rpcServer.closeWait()

# TTD is the value specified in the TestSpec + Genesis.Difficulty
proc setRealTTD*(t: TestEnv, ttdValue: int64) =
  let realTTD = t.gHeader.difficulty + ttdValue.u256
  t.chainDB.config.terminalTotalDifficulty = some(realTTD)
  t.ttd = realTTD
  t.clmock = newCLMocker(t.rpcClient, realTTD)

func gwei(n: int): GasInt {.compileTime.} =
  GasInt(n * (10 ^ 9))

proc makeNextTransaction*(t: TestEnv, recipient: EthAddress, amount: UInt256, payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let chainId = t.conf.networkParams.config.chainId
  let tx = Transaction(
    txType  : TxLegacy,
    chainId : chainId,
    nonce   : AccountNonce(t.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to      : some(recipient),
    value   : amount,
    payload : @payload
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, chainId, eip155 = true)

proc verifyPoWProgress*(t: TestEnv, lastBlockHash: Hash256): bool =
  let res = waitFor verifyPoWProgress(t.rpcClient, lastBlockHash)
  if res.isErr:
    error "verify PoW Progress error", msg=res.error
    return false

  true
