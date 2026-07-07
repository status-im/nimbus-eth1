# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[cpuinfo],
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  kzg4844/kzg,
  taskpools,
  ../../execution_chain/rpc,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/engine_client,
  ./eest_parser

import ../../tools/common/helpers as chp except HardFork
import ../../tools/evmstate/helpers except HardFork

export
  eest_parser

# Load eagerly to avoid race conditions - lazy kzg loading is not thread safe
discard loadTrustedSetupFromString(kzg.trustedSetup, 8)

# Common Type Definitions
type
  TestEnv* = ref object
    chain*: ForkedChainRef
    server*: Opt[RpcHttpServer]
    client*: Opt[RpcHttpClient]
    taskpool*: Taskpool

proc setupClient*(port: Port): RpcHttpClient =
  try:
    let client = newRpcHttpClient()
    waitFor client.connect("127.0.0.1", port, false)
    return client
  except CatchableError as exc:
    debugEcho "CONNECT ERROR: ", exc.msg
    quit(QuitFailure)

proc prepareEnv*(
    unit: UnitEnv,
    genesis: Header,
    rpcEnabled = false,
    statelessEnabled = false,
    parallelEnabled = false): TestEnv =

  try:
    let
      memDB = newCoreDbRef(DefaultDbMemory, enableCaches = true)
      ledger = LedgerRef.init(memDB.baseTxFrame())
      config = getChainConfig(unit.network)

    config.chainId = unit.config.chainid
    config.blobSchedule = unit.config.blobSchedule

    setupLedger(unit.pre, ledger)
    try:
      ledger.persist()
    except BlockAbortError as e:
      raiseAssert e.msg

    ledger.txFrame.persistHeaderAndSetHead(genesis).isOkOr:
      debugEcho "Failed to put genesis header into database: ", error
      return

    var testEnv = TestEnv()

    let
      com = CommonRef.new(memDB, config,
        statelessProviderEnabled = statelessEnabled,
        statelessWitnessValidation = false, # Running stateless execution separately in test runner
        optimisticStatePrefetch = parallelEnabled,
        balStatePrefetch = parallelEnabled)

    com.db.mpt.parallelStateRootComputation = parallelEnabled

    if parallelEnabled:
      let taskpool =
        try:
          Taskpool.new(numThreads = min(countProcessors(), 16))
        except CatchableError as exc:
          debugEcho "Failed to start taskpool: ", exc.msg
          quit(QuitFailure)
      com.taskpool = taskpool
      com.db.mpt.taskpool = taskpool
      testEnv.taskpool = taskpool

    let chain = ForkedChainRef.init(com, enableQueue = true, persistBatchSize = 1)

    testEnv.chain = chain
    testEnv.client = Opt.none(RpcHttpClient)
    testEnv.server = Opt.none(RpcHttpServer)

    if rpcEnabled:
      let
        txPool = TxPoolRef.new(chain)
        server = newRpcHttpServerWithParams("127.0.0.1:7717").valueOr:
          echo "Failed to create rpc server: ", error
          quit(QuitFailure)
        beaconEngine = BeaconEngineRef.new(txPool)
        serverApi = newServerAPI(txPool)

      setupServerAPI(serverApi, server, new AccountsManager)
      setupEngineAPI(beaconEngine, server)

      server.start()

      let client = setupClient(server.localAddress[0].port)

      testEnv.client = Opt.some(client)
      testEnv.server = Opt.some(server)

    return testEnv
  except ValueError as exc:
    debugEcho "Prepare env error: ", exc.msg
    quit(QuitFailure)

proc close*(env: TestEnv) =
  try:
    if env.client.isSome:
      waitFor env.client.get().close()
    if env.server.isSome:
      waitFor env.server.get().closeWait()
    waitFor env.chain.stopProcessingQueue()
    env.chain.com.db.close()
    if env.taskpool != nil:
      env.taskpool.shutdown()
  except CatchableError as exc:
    debugEcho "Close error: ", exc.msg
    quit(QuitFailure)
