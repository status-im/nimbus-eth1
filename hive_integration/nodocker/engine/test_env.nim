import
  chronicles,
  eth/keys,
  json_rpc/rpcclient,
  ../../../nimbus/config,
  ../../../nimbus/common,
  ./clmock,
  ./engine_client,
  ./client_pool,
  ./engine_env

export
  clmock,
  engine_client,
  client_pool,
  engine_env

type
  TestEnv* = ref object
    conf      : NimbusConf
    chainFile : string
    enableAuth: bool
    port      : int
    rpcPort   : int
    clients   : ClientPool
    clMock*   : CLMocker
    vaultKey  : PrivateKey

const
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"

proc makeEnv(conf: NimbusConf): TestEnv =
  let env = TestEnv(
    conf   : conf,
    port   : 30303,
    rpcPort: 8545,
    clients: ClientPool(),
  )

  env.vaultKey = PrivateKey.fromHex(vaultKeyHex).valueOr:
    echo error
    quit(QuitFailure)

  env

proc addEngine(env: TestEnv, conf: var NimbusConf): EngineEnv =
  conf.tcpPort = Port env.port
  conf.udpPort = Port env.port
  conf.rpcPort = Port env.rpcPort
  let engine = newEngineEnv(conf, env.chainFile, env.enableAuth)
  env.clients.add engine
  inc env.port
  inc env.rpcPort
  engine

proc setup(env: TestEnv, conf: var NimbusConf, chainFile: string, enableAuth: bool) =
  env.chainFile = chainFile
  env.enableAuth = enableAuth
  env.conf = conf
  discard env.addEngine(conf)

proc new*(_: type TestEnv, conf: NimbusConf): TestEnv =
  let env = makeEnv(conf)
  env.setup(env.conf, "", false)
  env

proc new*(_: type TestEnv, conf: ChainConfig): TestEnv =
  let env = makeEnv(envConfig(conf))
  env.setup(env.conf, "", false)
  env

proc new*(_: type TestEnv, chainFile: string, enableAuth: bool): TestEnv =
  let env = makeEnv(envConfig())
  env.setup(env.conf, chainFile, enableAuth)
  env

proc close*(env: TestEnv) =
  for eng in env.clients:
    eng.close()

proc addEngine*(env: TestEnv): EngineEnv =
  var conf = envConfig(env.conf.networkParams.config)
  env.addEngine(conf)

func client*(env: TestEnv): RpcHttpClient =
  env.clients.first.client

func engine*(env: TestEnv): EngineEnv =
  env.clients.first

proc setupCLMock*(env: TestEnv) =
  env.clmock = newCLMocker(env.clients, env.engine.com)

proc makeTx*(env: TestEnv, eng: EngineEnv, tc: BaseTx, nonce: AccountNonce): Transaction =
  eng.makeTx(env.vaultKey, tc, nonce)

proc makeTx*(env: TestEnv, eng: EngineEnv, tc: var BigInitcodeTx, nonce: AccountNonce): Transaction =
  eng.makeTx(env.vaultKey, tc, nonce)

proc sendNextTx*(env: TestEnv, eng: EngineEnv, tc: BaseTx): bool =
  eng.sendNextTx(env.vaultKey, tc)

proc sendTx*(env: TestEnv, eng: EngineEnv, tc: BaseTx, nonce: AccountNonce): bool =
  eng.sendTx(env.vaultKey, tc, nonce)

proc sendTx*(env: TestEnv, eng: EngineEnv, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  eng.sendTx(env.vaultKey, tc, nonce)


proc makeTx*(env: TestEnv, tc: BaseTx, nonce: AccountNonce): Transaction =
  env.engine.makeTx(env.vaultKey, tc, nonce)

proc makeTx*(env: TestEnv, tc: var BigInitcodeTx, nonce: AccountNonce): Transaction =
  env.engine.makeTx(env.vaultKey, tc, nonce)

proc sendNextTx*(env: TestEnv, tc: BaseTx): bool =
  env.engine.sendNextTx(env.vaultKey, tc)

proc sendTx*(env: TestEnv, tc: BaseTx, nonce: AccountNonce): bool =
  env.engine.sendTx(env.vaultKey, tc, nonce)

proc sendTx*(env: TestEnv, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  env.engine.sendTx(env.vaultKey, tc, nonce)

proc sendTx*(env: TestEnv, tx: Transaction): bool =
  env.engine.sendTx(tx)

proc verifyPoWProgress*(env: TestEnv, lastBlockHash: common.Hash256): bool =
  let res = waitFor env.client.verifyPoWProgress(lastBlockHash)
  if res.isErr:
    error "verify PoW Progress error", msg=res.error
    return false

  true

proc slotsToSafe*(env: TestEnv, x: int) =
  env.clMock.slotsToSafe = x

proc slotsToFinalized*(env: TestEnv, x: int) =
  env.clMock.slotsToFinalized = x
