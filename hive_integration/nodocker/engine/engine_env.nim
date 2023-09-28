import
  std/[os, math],
  eth/keys,
  eth/p2p as eth_p2p,
  chronos,
  json_rpc/[rpcserver, rpcclient],
  stew/[results, byteutils],
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
    sync/beacon,
    sync/handlers,
    beacon/beacon_engine,
    common
  ],
  ../../../tests/test_helpers,
  ./engine_client

export
  results

type
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

  EngineEnv* = ref object
    conf   : NimbusConf
    com    : CommonRef
    node   : EthereumNode
    server : RpcHttpServer
    sealer : SealingEngineRef
    ttd    : DifficultyInt
    tx     : Transaction
    nonce  : uint64
    client : RpcHttpClient
    sync   : BeaconSyncRef

const
  baseFolder  = "hive_integration/nodocker/engine"
  genesisFile = baseFolder & "/init/genesis.json"
  sealerKey   = baseFolder & "/init/sealer.key"
  chainFolder = baseFolder & "/chains"

  # This is the account that sends vault funding transactions.
  vaultAddr*  = hexToByteArray[20]("0xcf49fda3be353c69b41ed96333cd24302da4556f")
  jwtSecret   = "0x7365637265747365637265747365637265747365637265747365637265747365"


proc makeCom*(conf: NimbusConf): CommonRef =
  CommonRef.new(
    newCoreDbRef LegacyDbMemory,
    conf.pruneMode == PruneMode.Full,
    conf.networkId,
    conf.networkParams
  )

proc envConfig*(): NimbusConf =
  makeConfig(@[
    "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
    "--custom-network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

proc envConfig*(conf: ChainConfig): NimbusConf =
  result = envConfig()
  result.networkParams.config = conf

proc newEngineEnv*(conf: var NimbusConf, chainFile: string, enableAuth: bool): EngineEnv =
  if chainFile.len > 0:
    # disable clique if we are using PoW chain
    conf.networkParams.config.consensusType = ConsensusType.POW

  let ctx = newEthContext()
  ctx.am.importPrivateKey(sealerKey).isOkOr:
    echo error
    quit(QuitFailure)

  let
    node  = setupEthNode(conf, ctx)
    com   = makeCom(conf)
    chain = newChain(com)

  com.initializeEmptyDb()
  let txPool = TxPoolRef.new(com, conf.engineSigner)

  node.addEthHandlerCapability(
    node.peerPool,
    chain,
    txPool)

  # txPool must be informed of active head
  # so it can know the latest account state
  let head = com.db.getCanonicalHead()
  doAssert txPool.smartHead(head)

  var key: JwtSharedKey
  key.fromHex(jwtSecret).isOkOr:
    echo "JWT SECRET ERROR: ", error
    quit(QuitFailure)

  let
    hooks  = if enableAuth: @[httpJwtAuth(key)]
             else: @[]
    server = newRpcHttpServer(["127.0.0.1:" & $conf.rpcPort], hooks)
    sealer = SealingEngineRef.new(
              chain, ctx, conf.engineSigner,
              txPool, EngineStopped)
    sync   = if com.ttd().isSome:
               BeaconSyncRef.init(node, chain, ctx.rng, conf.maxPeers, id=conf.tcpPort.int)
             else:
               BeaconSyncRef(nil)
    beaconEngine = BeaconEngineRef.new(txPool, chain)

  setupEthRpc(node, ctx, com, txPool, server)
  setupEngineAPI(beaconEngine, server)
  setupDebugRpc(com, server)

  # Do not start clique sealing engine if we are using a Proof of Work chain file
  if chainFile.len > 0:
    if not importRlpBlock(chainFolder / chainFile, com):
      quit(QuitFailure)
  elif not enableAuth:
    sealer.start()

  server.start()

  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", conf.rpcPort, false)

  if com.ttd().isSome:
    sync.start()

  node.startListening()

  EngineEnv(
    conf   : conf,
    com    : com,
    node   : node,
    server : server,
    sealer : sealer,
    client : client,
    sync   : sync
  )

proc close*(env: EngineEnv) =
  waitFor env.node.closeWait()
  if not env.sync.isNil:
    env.sync.stop()
  waitFor env.client.close()
  waitFor env.sealer.stop()
  waitFor env.server.closeWait()

proc setRealTTD*(env: EngineEnv, ttdValue: int64) =
  let genesis = env.com.genesisHeader
  let realTTD = genesis.difficulty + ttdValue.u256
  env.com.setTTD some(realTTD)
  env.ttd = realTTD

func rpcPort*(env: EngineEnv): Port =
  env.conf.rpcPort

func client*(env: EngineEnv): RpcHttpClient =
  env.client

func ttd*(env: EngineEnv): UInt256 =
  env.ttd

func com*(env: EngineEnv): CommonRef =
  env.com

func node*(env: EngineEnv): ENode =
  env.node.listeningAddress

proc connect*(env: EngineEnv, node: ENode) =
  waitFor env.node.connectToNode(node)

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

proc makeTx*(env: EngineEnv, vaultKey: PrivateKey, tc: BaseTx, nonce: AccountNonce): Transaction =
  const
    gasPrice = 30.gwei
    gasTipPrice = 1.gwei

    gasFeeCap = gasPrice
    gasTipCap = gasTipPrice

  let chainId = env.conf.networkParams.config.chainId
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

  signTransaction(tx, vaultKey, chainId, eip155 = true)

proc makeTx*(env: EngineEnv, vaultKey: PrivateKey, tc: var BigInitcodeTx, nonce: AccountNonce): Transaction =
  if tc.payload.len == 0:
    # Prepare initcode payload
    if tc.initcode.len != 0:
      doAssert(tc.initcode.len <= tc.initcodeLength, "invalid initcode (too big)")
      tc.payload = tc.initcode

    while tc.payload.len < tc.initcodeLength:
      tc.payload.add tc.padByte

  doAssert(tc.recipient.isNone, "invalid configuration for big contract tx creator")
  env.makeTx(vaultKey, tc.BaseTx, nonce)

proc sendNextTx*(env: EngineEnv, vaultKey: PrivateKey, tc: BaseTx): bool =
  env.tx = env.makeTx(vaultKey, tc, env.nonce)
  inc env.nonce
  let rr = env.client.sendTransaction(env.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(env: EngineEnv, vaultKey: PrivateKey, tc: BaseTx, nonce: AccountNonce): bool =
  env.tx = env.makeTx(vaultKey, tc, nonce)
  let rr = env.client.sendTransaction(env.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(env: EngineEnv, vaultKey: PrivateKey, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  env.tx = env.makeTx(vaultKey, tc, nonce)
  let rr = env.client.sendTransaction(env.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true

proc sendTx*(env: EngineEnv, tx: Transaction): bool =
  env.tx = tx
  let rr = env.client.sendTransaction(env.tx)
  if rr.isErr:
    error "Unable to send transaction", msg=rr.error
    return false
  return true
