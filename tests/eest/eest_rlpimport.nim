# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# To make the isMainModule functionality work
{.define: unittest2DisableParamFiltering.}

import
  std/[json, os, typetraits, cpuinfo],
  chronos,
  unittest2,
  kzg4844/kzg,
  stew/byteutils,
  web3/conversions,
  web3/eth_api_types,
  eth/common/blocks_rlp,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/beacon/web3_eth_conv,
  ../../execution_chain/core/block_import,
  ../../execution_chain/common/common,
  ../../tools/common/helpers,
  ./eest_parser

# Load eagerly to avoid race conditions - lazy kzg loading is not thread safe
discard loadTrustedSetupFromString(kzg.trustedSetup, 8)

type
  TestEnv = ref object
    chain: ForkedChainRef
    taskpool: Taskpool

func toGenesis(unit: UnitEnv): Genesis =
  template header(): auto = unit.genesisBlockHeader
  Genesis(
    nonce      : header.nonce,
    timestamp  : EthTime header.timestamp,
    extraData  : distinctBase header.extraData,
    gasLimit   : GasInt header.gasLimit,
    difficulty : header.difficulty,
    mixHash    : header.mixHash,
    coinbase   : header.coinbase,
    alloc      : unit.pre,
    number     : uint64 header.number,
    gasUsed    : GasInt header.gasUsed,
    parentHash : header.parentHash,
    baseFeePerGas: header.baseFeePerGas,
    blobGasUsed  : u64 header.blobGasUsed,
    excessBlobGas: u64 header.excessBlobGas,
    parentBeaconBlockRoot: header.parentBeaconBlockRoot,
    slotNumber : u64 header.slotNumber,
  )

func toNetworkParams(unit: UnitEnv): NetworkParams =
  let config = getChainConfig(unit.network).expect("ok")
  config.chainId = unit.config.chainid
  config.blobSchedule = unit.config.blobSchedule

  NetworkParams(
    config   : config,
    genesis  : unit.toGenesis,
    networkId: config.chainId,
    custom   : true,
  )

proc prepareEnv(unit: UnitEnv, parallelEnabled = false): TestEnv =
  let
    memDB = newCoreDbRef(DefaultDbMemory, enableCaches = true)
    env = TestEnv()
    params = unit.toNetworkParams()
    com = CommonRef.new(memDB, params,
      parallelSenderRecovery = parallelEnabled,
      optimisticStatePrefetch = parallelEnabled,
      balStatePrefetch = parallelEnabled,
      balParallelExecution = parallelEnabled
    )

  com.db.mpt.parallelStateRootComputation = parallelEnabled
  if parallelEnabled:
    let taskpool =
      try:
        # Use between 2 and 16 threads
        Taskpool.new(numThreads = max(min(countProcessors(), 16), 2))
      except CatchableError as exc:
        debugEcho "Failed to start taskpool: ", exc.msg
        quit(QuitFailure)
    com.taskpool = taskpool
    com.db.mpt.taskpool = taskpool
    env.taskpool = taskpool

  let chain = ForkedChainRef.init(com, enableQueue = true, persistBatchSize = 1)
  env.chain = chain
  env

proc close(env: TestEnv) =
  try:
    waitFor env.chain.stopProcessingQueue()
    env.chain.com.db.close()
    if env.taskpool != nil:
      env.taskpool.shutdown()
  except CatchableError as exc:
    debugEcho "Close error: ", exc.msg
    quit(QuitFailure)

proc parseBlocks(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
        #bal: parseBAL(x),
        badBlock: "expectException" in x,
      )
    except RlpError:
      # invalid rlp will not participate in block validation
      # e.g. invalid rlp received from network
      discard

proc rootExists(db: CoreDbTxRef; root: Hash32): bool =
  let state = db.getStateRoot().valueOr:
    return false
  state == root

proc runTest(env: TestEnv, unit: BlockchainUnitEnv): Result[void, string] =
  let
    blocks = parseBlocks(unit.blocks)

  try:
    for iBlock in blocks:
      let
        rlpBytes = rlp.encode(iBlock.blk)
        res = waitFor importRlpBlocks(rlpBytes, env.chain, true)

      if iBlock.badBlock:
        if res.isOk:
          return err("[BUG] Bad block imported successfully")
      else:
        if res.isErr:
          return err("[BUG] Good block rejected")
  except CancelledError:
    raiseAssert "Nothing cancels the future"

  let
    latestStateRoot = env.chain.latestHeader.stateRoot

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err("Latest block hash mismatch, got: " & $headHash &
      " expected: " & $unit.lastblockhash)

  if not env.chain.txFrame(headHash).rootExists(latestStateRoot):
    return err("Latest stateRoot does not exist in the database")

  ok()

proc processFile*(filePath: string, statelessEnabled = false, parallelEnabled = false, skipFiles: seq[string] = @[]) =
  let fixture = parseFixture(filePath, BlockchainFixture)
  let fileName = filePath.splitPath().tail

  for unit in fixture.units:
    let
      testName = unit.name
      testUnit = unit.unit
    test testName & " from " & filePath:
      if fileName in skipFiles:
        skip()
      else:
        let env = prepareEnv(testUnit, parallelEnabled)
        let testResult = env.runTest(testUnit)
        check testResult == Result[void, string].ok()
        env.close()

when isMainModule:
  import std/cmdline

  if paramCount() == 0:
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " vector.json"
    quit(QuitFailure)

  processFile(paramStr(1), false)
