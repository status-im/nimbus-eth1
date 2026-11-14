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
  chronos,
  kzg4844/kzg,
  taskpools,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/common/common,
  ./eest_parser

import ../../tools/common/helpers as chp except HardFork

export
  eest_parser

# Load eagerly to avoid race conditions - lazy kzg loading is not thread safe
discard loadTrustedSetupFromString(kzg.trustedSetup, 8)

# Common Type Definitions
type
  TestEnv* = ref object
    chain*: ForkedChainRef

var sharedTaskpool: Taskpool

proc getSharedTaskpool(): Taskpool =
  ## Lazily create the single taskpool shared by the full test suite
  if sharedTaskpool.isNil:
    try:
      # Use between 2 and 16 threads
      sharedTaskpool = Taskpool.new(numThreads = max(min(countProcessors(), 16), 2))
    except CatchableError as exc:
      debugEcho "Failed to start taskpool: ", exc.msg
      quit(QuitFailure)
  sharedTaskpool

proc newForkedChain*(
    unit: UnitEnv,
    genesis: Header,
    statelessEnabled = false,
    parallelEnabled = false,
): ForkedChainRef =
  let
    memDB = newCoreDbRef(DefaultDbMemory, enableCaches = true)
    config = getChainConfig(unit.network).expect("ok")

  config.chainId = unit.config.chainid
  config.blobSchedule = unit.config.blobSchedule

  discard writeGenesisAlloc(unit.pre, memDB.baseTxFrame())

  let ledger = LedgerRef.init(memDB.baseTxFrame())

  ledger.txFrame.persistHeaderAndSetHead(genesis).isOkOr:
    debugEcho "Failed to put genesis header into database: ", error
    return

  let com = CommonRef.new(memDB, config,
    statelessProvider = statelessEnabled,
    statelessWitnessValidation = false, # Running stateless execution separately in test runner
    parallelSenderRecovery = parallelEnabled,
    optimisticStatePrefetch = parallelEnabled,
    balStatePrefetch = parallelEnabled,
    balParallelExecution = parallelEnabled
  )
  com.db.mpt.parallelStateRootComputation = parallelEnabled

  if parallelEnabled:
    let taskpool = getSharedTaskpool()
    com.taskpool = taskpool
    com.db.mpt.taskpool = taskpool

  ForkedChainRef.init(com, persistBatchSize = 1)

proc prepareEnv*(
    unit: UnitEnv,
    genesis: Header,
    statelessEnabled = false,
    parallelEnabled = false,
): TestEnv =
  try:
    TestEnv(chain: newForkedChain(unit, genesis, statelessEnabled, parallelEnabled))
  except ValueError as exc:
    debugEcho "Prepare env error: ", exc.msg
    quit(QuitFailure)

proc closeChain*(chain: ForkedChainRef) =
  waitFor chain.flushBaseLoop()
  chain.com.db.close()

proc close*(env: TestEnv) =
  try:
    closeChain(env.chain)
  except CatchableError as exc:
    debugEcho "Close error: ", exc.msg
    quit(QuitFailure)
