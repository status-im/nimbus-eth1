import
  std/[os, times, math],
  eth/keys,
  eth/p2p as eth_p2p,
  stew/[results, byteutils],
  json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/[
    config,
    constants,
    transaction,
    core/sealer,
    core/chain,
    core/tx_pool,
    core/block_import,
    rpc,
    sync/protocol,
    rpc/merge/merger,
    common
  ],
  ../../../tests/test_helpers,
  "."/[clmock, engine_client]

import web3/engine_api_types
from web3/ethtypes as web3types import nil

export
  common, engine_api_types, times,
  results, constants,
  TypedTransaction, clmock, engine_client

type
  EthBlockHeader* = common.BlockHeader

  TestEnv* = ref object
    conf*: NimbusConf
    ctx: EthContext
    ethNode: EthereumNode
    com: CommonRef
    chainRef: ChainRef
    rpcServer: RpcHttpServer
    sealingEngine: SealingEngineRef
    rpcClient*: RpcHttpClient
    gHeader*: EthBlockHeader
    ttd*: DifficultyInt
    clMock*: CLMocker
    nonce*: uint64
    vaultKey*: PrivateKey
    tx*: Transaction

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
  chainFolder = baseFolder / "chains"

  # This is the account that sends vault funding transactions.
  vaultAccountAddr* = hexToByteArray[20]("0xcf49fda3be353c69b41ed96333cd24302da4556f")
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"
  jwtSecret = "0x7365637265747365637265747365637265747365637265747365637265747365"

proc setupELClient*(t: TestEnv, chainFile: string, enableAuth: bool) =
  if chainFile.len > 0:
    # disable clique if we are using PoW chain
    t.conf.networkParams.config.consensusType = ConsensusType.POW

  t.ctx  = newEthContext()
  let res = t.ctx.am.importPrivateKey(sealerKey)
  if res.isErr:
    echo res.error()
    quit(QuitFailure)

  t.ethNode = setupEthNode(t.conf, t.ctx, eth)
  t.com = CommonRef.new(
      newCoreDbRef LegacyDbMemory,
      t.conf.pruneMode == PruneMode.Full,
      t.conf.networkId,
      t.conf.networkParams
    )
  t.chainRef = newChain(t.com)

  t.com.initializeEmptyDb()
  let txPool = TxPoolRef.new(t.com, t.conf.engineSigner)

  var key: JwtSharedKey
  let kr = key.fromHex(jwtSecret)
  if kr.isErr:
    echo "JWT SECRET ERROR: ", kr.error
    quit(QuitFailure)

  let hooks = if enableAuth:
                @[httpJwtAuth(key)]
              else:
                @[]

  t.rpcServer = newRpcHttpServer(["127.0.0.1:" & $t.conf.rpcPort], hooks)
  t.sealingEngine = SealingEngineRef.new(
    t.chainRef, t.ctx, t.conf.engineSigner,
    txPool, EngineStopped
  )

  let merger = MergerRef.new(t.com.db)
  setupEthRpc(t.ethNode, t.ctx, t.com, txPool, t.rpcServer)
  setupEngineAPI(t.sealingEngine, t.rpcServer, merger)
  setupDebugRpc(t.com, t.rpcServer)

  # Do not start clique sealing engine if we are using a Proof of Work chain file
  if chainFile.len > 0:
    if not importRlpBlock(chainFolder / chainFile, t.com):
      quit(QuitFailure)
  elif not enableAuth:
    t.sealingEngine.start()

  t.rpcServer.start()

  t.rpcClient = newRpcHttpClient()
  waitFor t.rpcClient.connect("127.0.0.1", t.conf.rpcPort, false)
  t.gHeader = t.com.genesisHeader

  let kRes = PrivateKey.fromHex(vaultKeyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  t.vaultKey = kRes.get

proc setupELClient*(chainFile: string, enableAuth: bool): TestEnv =
  result = TestEnv(
    conf: makeConfig(@["--engine-signer:658bdf435d810c91414ec09147daa6db62406379", "--custom-network:" & genesisFile])
  )
  setupELClient(result, chainFile, enableAuth)

proc stopELClient*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.sealingEngine.stop()
  #waitFor t.rpcServer.stop()
  waitFor t.rpcServer.closeWait()

# TTD is the value specified in the TestSpec + Genesis.Difficulty
proc setRealTTD*(t: TestEnv, ttdValue: int64) =
  let realTTD = t.gHeader.difficulty + ttdValue.u256
  t.com.setTTD some(realTTD)
  t.ttd = realTTD
  t.clmock = newCLMocker(t.rpcClient, realTTD)

proc slotsToSafe*(t: TestEnv, x: int) =
  t.clMock.slotsToSafe = x

proc slotsToFinalized*(t: TestEnv, x: int) =
  t.clMock.slotsToFinalized = x

func gwei(n: int64): GasInt {.compileTime.} =
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

proc verifyPoWProgress*(t: TestEnv, lastBlockHash: ethtypes.Hash256): bool =
  let res = waitFor verifyPoWProgress(t.rpcClient, lastBlockHash)
  if res.isErr:
    error "verify PoW Progress error", msg=res.error
    return false

  true
