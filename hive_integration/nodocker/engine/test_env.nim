# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  chronicles,
  eth/keys,
  stew/results,
  json_rpc/rpcclient,
  ../../../nimbus/config,
  ../../../nimbus/common,
  ./clmock,
  ./engine_client,
  ./client_pool,
  ./engine_env,
  ./tx_sender,
  ./types,
  ./cancun/customizer

export
  clmock,
  engine_client,
  client_pool,
  engine_env,
  tx_sender

type
  TestEnv* = ref object
    conf      : NimbusConf
    chainFile : string
    enableAuth: bool
    port      : int
    rpcPort   : int
    clients   : ClientPool
    sender    : TxSender
    clMock*   : CLMocker

proc makeEnv(conf: NimbusConf): TestEnv =
  TestEnv(
    conf   : conf,
    port   : 30303,
    rpcPort: 8545,
    clients: ClientPool(),
    sender : TxSender.new(conf.networkParams),
  )

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

func client*(env: TestEnv): RpcHttpClient =
  env.clients.first.client

func engine*(env: TestEnv): EngineEnv =
  env.clients.first

func sender*(env: TesTenv): TxSender =
  env.sender

proc setupCLMock*(env: TestEnv) =
  env.clmock = newCLMocker(env.engine, env.engine.com)

proc addEngine*(env: TestEnv, addToCL: bool = true, connectBootNode: bool = true): EngineEnv =
  doAssert(env.clMock.isNil.not)
  var conf = env.conf # clone the conf
  let eng = env.addEngine(conf)
  if connectBootNode:
    eng.connect(env.engine.node)
  if addToCL:
    env.clMock.addEngine(eng)
  eng

func engines*(env: TestEnv, idx: int): EngineEnv =
  env.clients[idx]

func numEngines*(env: TestEnv): int =
  env.clients.len

func accounts*(env: TestEnv, idx: int): TestAccount =
  env.sender.getAccount(idx)

proc makeTx*(env: TestEnv, tc: BaseTx, nonce: AccountNonce): Transaction =
  env.sender.makeTx(tc, nonce)

proc makeTx*(env: TestEnv, tc: BigInitcodeTx, nonce: AccountNonce): Transaction =
  env.sender.makeTx(tc, nonce)

proc makeTxs*(env: TestEnv, tc: BaseTx, num: int): seq[Transaction] =
  result = newSeqOfCap[Transaction](num)
  for _ in 0..<num:
    result.add env.sender.makeNextTx(tc)

proc makeNextTx*(env: TestEnv, tc: BaseTx): Transaction =
  env.sender.makeNextTx(tc)

proc sendNextTx*(env: TestEnv, eng: EngineEnv, tc: BaseTx): bool =
  env.sender.sendNextTx(eng.client, tc)

proc sendNextTxs*(env: TestEnv, eng: EngineEnv, tc: BaseTx, num: int): bool =
  for i in 0..<num:
    if not env.sender.sendNextTx(eng.client, tc):
      return false
  return true

proc sendTx*(env: TestEnv, eng: EngineEnv, tc: BaseTx, nonce: AccountNonce): bool =
  env.sender.sendTx(eng.client, tc, nonce)

proc sendTx*(env: TestEnv, eng: EngineEnv, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  env.sender.sendTx(eng.client, tc, nonce)

proc sendTxs*(env: TestEnv, eng: EngineEnv, txs: openArray[Transaction]): bool =
  for tx in txs:
    if not sendTx(eng.client, tx):
      return false
  true

proc sendNextTx*(env: TestEnv, tc: BaseTx): bool =
  let client = env.engine.client
  env.sender.sendNextTx(client, tc)

proc sendTx*(env: TestEnv, tc: BaseTx, nonce: AccountNonce): bool =
  let client = env.engine.client
  env.sender.sendTx(client, tc, nonce)

proc sendTx*(env: TestEnv, tc: BigInitcodeTx, nonce: AccountNonce): bool =
  let client = env.engine.client
  env.sender.sendTx(client, tc, nonce)

proc sendTx*(env: TestEnv, tx: Transaction): bool =
  let client = env.engine.client
  sendTx(client, tx)

proc sendTx*(env: TestEnv, sender: TestAccount, eng: EngineEnv, tc: BlobTx): Result[Transaction, void] =
  env.sender.sendTx(sender, eng.client, tc)

proc replaceTx*(env: TestEnv, sender: TestAccount, eng: EngineEnv, tc: BlobTx): Result[Transaction, void] =
  env.sender.replaceTx(sender, eng.client, tc)

proc makeTx*(env: TestEnv, tc: BaseTx, sender: TestAccount, nonce: AccountNonce): Transaction =
  env.sender.makeTx(tc, sender, nonce)

proc customizeTransaction*(env: TestEnv,
                           acc: TestAccount,
                           baseTx: Transaction,
                           custTx: CustomTransactionData): Transaction =
  env.sender.customizeTransaction(acc, baseTx, custTx)

proc generateInvalidPayload*(env: TestEnv,
                             data: ExecutableData,
                             payloadField: InvalidPayloadBlockField): ExecutableData =
  env.sender.generateInvalidPayload(data, payloadField)

proc verifyPoWProgress*(env: TestEnv, lastBlockHash: common.Hash256): bool =
  let res = waitFor env.client.verifyPoWProgress(lastBlockHash)
  if res.isErr:
    error "verify PoW Progress error", msg=res.error
    return false

  true
