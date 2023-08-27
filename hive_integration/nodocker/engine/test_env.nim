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
    beacon/beacon_engine,
    common
  ],
  ../../../tests/test_helpers,
  "."/[clmock, engine_client]

export
  common, times,
  results, constants,
  clmock, engine_client

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
    vaultKey*: PrivateKey
    tx*: Transaction
    nonce*: uint64

  BaseTx* = object of RootObj
    recipient*: Option[EthAddress]
    gasLimit* : GasInt
    amount*   : UInt256
    payload*  : seq[byte]
    txType*   : Option[TxType]

  BigInitcodeTx* = object of BaseTx
    initcodeLength*: int
    padByte*       : uint8
    initcode*      : seq[byte]

const
  baseFolder  = "hive_integration/nodocker/engine"
  genesisFile = baseFolder / "init/genesis.json"
  sealerKey   = baseFolder / "init/sealer.key"
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

  # txPool must be informed of active head
  # so it can know the latest account state
  let head = t.com.db.getCanonicalHead()
  doAssert txPool.smartHead(head)

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

  let beaconEngine = BeaconEngineRef.new(txPool, t.chainRef)
  setupEthRpc(t.ethNode, t.ctx, t.com, txPool, t.rpcServer)
  setupEngineAPI(beaconEngine, t.rpcServer)
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

proc setupELClient*(conf: ChainConfig): TestEnv =
  result = TestEnv(
    conf: makeConfig(@["--engine-signer:658bdf435d810c91414ec09147daa6db62406379", "--custom-network:" & genesisFile])
  )
  result.conf.networkParams.config = conf
  setupELClient(result, "", false)

proc newTestEnv*(): TestEnv =
  TestEnv(
    conf: makeConfig(@["--engine-signer:658bdf435d810c91414ec09147daa6db62406379", "--custom-network:" & genesisFile])
  )

proc newTestEnv*(conf: ChainConfig): TestEnv =
  result = TestEnv(
    conf: makeConfig(@["--engine-signer:658bdf435d810c91414ec09147daa6db62406379", "--custom-network:" & genesisFile])
  )
  result.conf.networkParams.config = conf

proc stopELClient*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.sealingEngine.stop()
  waitFor t.rpcServer.closeWait()

# TTD is the value specified in the TestSpec + Genesis.Difficulty
proc setRealTTD*(t: TestEnv, ttdValue: int64) =
  let realTTD = t.gHeader.difficulty + ttdValue.u256
  t.com.setTTD some(realTTD)
  t.ttd = realTTD
  t.clmock = newCLMocker(t.rpcClient, t.com)

proc slotsToSafe*(t: TestEnv, x: int) =
  t.clMock.slotsToSafe = x

proc slotsToFinalized*(t: TestEnv, x: int) =
  t.clMock.slotsToFinalized = x

func gwei(n: int64): GasInt {.compileTime.} =
  GasInt(n * (10 ^ 9))

proc getTxType(tc: BaseTx, nonce: uint64): TxType =
  if tc.txType.isNone:
    if nonce mod 2 == 0:
      TxLegacy
    else:
      TxEIP1559
  else:
    tc.txType.get

proc makeTx*(t: TestEnv, tc: BaseTx, nonce: AccountNonce): Transaction =
  const
    gasPrice = 30.gwei
    gasTipPrice = 1.gwei

    gasFeeCap = gasPrice
    gasTipCap = gasTipPrice

  let chainId = t.conf.networkParams.config.chainId
  let txType = tc.getTxType(nonce)

  # Build the transaction depending on the specified type
  let tx = if txType == TxLegacy:
             Transaction(
               txType  : TxLegacy,
               nonce   : nonce,
               to      : tc.recipient,
               value   : tc.amount,
               gasLimit: tc.gasLimit,
               gasPrice: gasPrice,
               payload : tc.payload
             )
           else:
             Transaction(
               txType  : TxEIP1559,
               nonce   : nonce,
               gasLimit: tc.gasLimit,
               maxFee  : gasFeeCap,
               maxPriorityFee: gasTipCap,
               to      : tc.recipient,
               value   : tc.amount,
               payload : tc.payload,
               chainId : chainId
             )

  signTransaction(tx, t.vaultKey, chainId, eip155 = true)

proc makeTx*(t: TestEnv, tc: var BigInitcodeTx, nonce: AccountNonce): Transaction =
  if tc.payload.len == 0:
    # Prepare initcode payload
    if tc.initcode.len != 0:
      doAssert(tc.initcode.len <= tc.initcodeLength, "invalid initcode (too big)")
      tc.payload = tc.initcode

    while tc.payload.len < tc.initcodeLength:
      tc.payload.add tc.padByte

  doAssert(tc.recipient.isNone, "invalid configuration for big contract tx creator")
  t.makeTx(tc.BaseTx, nonce)

proc sendNextTx*(t: TestEnv, tc: BaseTx): bool =
  t.tx = t.makeTx(tc, t.nonce)
  inc t.nonce
  let rr = t.rpcClient.sendTransaction(t.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(t: TestEnv, tc: BaseTx, nonce: AccountNonce): bool =
  t.tx = t.makeTx(tc, nonce)
  let rr = t.rpcClient.sendTransaction(t.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(t: TestEnv, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  t.tx = t.makeTx(tc, nonce)
  let rr = t.rpcClient.sendTransaction(t.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(t: TestEnv, tx: Transaction): bool =
  t.tx = tx
  let rr = t.rpcClient.sendTransaction(t.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc verifyPoWProgress*(t: TestEnv, lastBlockHash: ethtypes.Hash256): bool =
  let res = waitFor verifyPoWProgress(t.rpcClient, lastBlockHash)
  if res.isErr:
    error "verify PoW Progress error", msg=res.error
    return false

  true
