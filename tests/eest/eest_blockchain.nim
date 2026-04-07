# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/json,
  eth/common/headers_rlp,
  web3/eth_api_types,
  web3/engine_api_types,
  web3/primitives,
  web3/conversions,
  web3/execution_types,
  json_rpc/rpcclient,
  json_rpc/rpcserver,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/executor,
  ../../execution_chain/core/validate,
  ../../execution_chain/evm/state,
  ../../execution_chain/evm/types,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/engine_client,
  ./eest_helpers,
  stew/byteutils,
  chronos

import ../../tools/common/helpers as chp except HardFork
import ../../tools/evmstate/helpers except HardFork

proc parseBlocks*(node: JsonNode): seq[BlockDesc] =
  for x in node:
    try:
      let blockRLP = hexToSeqByte(x["rlp"].getStr)
      let blk = rlp.decode(blockRLP, EthBlock)
      result.add BlockDesc(
        blk: blk,
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

proc runTest(env: TestEnv, unit: BlockchainUnitEnv): Future[Result[void, string]] {.async.} =
  let blocks = parseBlocks(unit.blocks)
  var lastStateRoot = unit.genesisBlockHeader.stateRoot

  for blk in blocks:
    let res = await env.chain.importBlock(blk.blk, finalized = true)
    if res.isOk:
      if unit.lastblockhash == blk.blk.header.computeBlockHash:
        lastStateRoot = blk.blk.header.stateRoot
      if blk.badBlock:
        return err("A bug? bad block imported")
    else:
      if not blk.badBlock:
        return err("A bug? good block rejected: " & res.error)

  (await env.chain.forkChoice(unit.lastblockhash, unit.lastblockhash)).isOkOr:
    return err("A bug? fork choice failed")

  let headHash = env.chain.latestHash
  if headHash != unit.lastblockhash:
    return err("lastestBlockHash mismatch, get: " & $headHash &
      " expect: " & $unit.lastblockhash)

  if not env.chain.txFrame(headHash).rootExists(lastStateRoot):
    return err("Last stateRoot not exists")

  ok()

proc processFile*(fileName: string, statelessEnabled = false): bool =
  let
    fixture = parseFixture(fileName, BlockchainFixture)

  var testPass = true
  for unit in fixture.units:
    let header = unit.unit.genesisBlockHeader.to(Header)
    doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)
    let env = prepareEnv(unit.unit, header, rpcEnabled = false, statelessEnabled)
    (waitFor env.runTest(unit.unit)).isOkOr:
      echo "\nTestName: ", unit.name, " RunTest error: ", error, "\n"
      testPass = false
    env.close()

  return testPass

proc runTestFast(
    com: CommonRef,
    parentHeader: Header,
    baseTxFrame: CoreDbTxRef,
    unit: BlockchainUnitEnv): Result[void, string] =
  ## Execute blocks directly through the executor, bypassing ForkedChainRef.
  let blocks = parseBlocks(unit.blocks)
  var
    parent = parentHeader
    currentFrame = baseTxFrame

  for blk in blocks:
    let childFrame = currentFrame.txFrameBegin()

    let vmState = BaseVMState()
    vmState.init(
      parent = parent,
      header = blk.blk.header,
      com = com,
      txFrame = childFrame,
    )

    # Header + kinship validation (gas limits, timestamps, etc.)
    let valRes = com.validateHeaderAndKinship(
      blk.blk,
      blockAccessList = Opt.none(BlockAccessListRef),
      skipPreExecBalCheck = true,
      parent,
      childFrame)
    if valRes.isErr:
      if blk.badBlock:
        childFrame.dispose()
        continue
      else:
        childFrame.dispose()
        return err("Good block failed validation: " & valRes.error)

    # Execute the block through the executor directly
    let res = vmState.processBlock(
      blk.blk,
      skipValidation = false,
      skipReceipts = false,
      skipUncles = true,
      skipStateRootCheck = false,
      skipPostExecBalCheck = true,
    )

    if res.isOk:
      if blk.badBlock:
        childFrame.dispose()
        return err("A bug? bad block imported")
      # Persist the header so the next block can look up its parent
      childFrame.persistHeader(
        blk.blk.header.computeBlockHash, blk.blk.header).isOkOr:
        childFrame.dispose()
        return err("Failed to persist header: " & error)
      parent = blk.blk.header
      currentFrame = childFrame
    else:
      childFrame.dispose()
      if not blk.badBlock:
        return err("Good block rejected: " & res.error)

  # Verify final state root
  let stateRoot = currentFrame.getStateRoot().valueOr:
    return err("Failed to get state root")
  if stateRoot != parent.stateRoot:
    return err("Final stateRoot mismatch: got " & $stateRoot &
      " expected " & $parent.stateRoot)

  ok()

proc processFileFast*(fileName: string): bool =
  let
    fixture = parseFixture(fileName, BlockchainFixture)

  var testPass = true
  for unit in fixture.units:
    try:
      let
        header = unit.unit.genesisBlockHeader.to(Header)
        memDB = newCoreDbRef DefaultDbMemory
        baseTx = memDB.baseTxFrame()
        ledger = LedgerRef.init(baseTx)
        config = getChainConfig(unit.unit.network)

      config.chainId = unit.unit.config.chainid
      config.blobSchedule = unit.unit.config.blobSchedule

      doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)

      setupLedger(unit.unit.pre, ledger)
      ledger.persist()

      baseTx.persistHeaderAndSetHead(header).isOkOr:
        echo "\nTestName: ", unit.name, " Failed to persist genesis: ", error, "\n"
        testPass = false
        continue

      let com = CommonRef.new(memDB, config)

      let res = runTestFast(com, header, baseTx, unit.unit)
      if res.isErr:
        echo "\nTestName: ", unit.name, " RunTest error: ", res.error, "\n"
        testPass = false
    except ValueError as exc:
      echo "\nTestName: ", unit.name, " Error: ", exc.msg, "\n"
      testPass = false

  return testPass

when isMainModule:
  import
    std/[os, parseopt, strutils]

  type
    TestResult = object
      name: string
      pass: bool
      error: string

  proc collectJsonFiles(path: string): seq[string] =
    if fileExists(path):
      return @[path]
    for entry in walkDirRec(path):
      if entry.endsWith(".json") and "/.meta/" notin entry:
        result.add(entry)

  proc printUsage() =
    let testFile = getAppFilename().splitPath().tail
    echo "Usage: " & testFile & " [options] <file-or-directory>"
    echo ""
    echo "Options:"
    echo "  --fast             Bypass ForkedChainRef; call executor directly"
    echo "  --run=<pattern>    Substring filter on file paths"
    echo "  --json             Output results as JSON array"
    echo "  --workers=<N>      Number of workers (accepted, runs sequentially)"
    echo ""
    echo "Examples:"
    echo "  " & testFile & " vector.json"
    echo "  " & testFile & " --fast /path/to/blockchain_tests/"
    echo "  " & testFile & " --json /path/to/blockchain_tests/"
    echo "  " & testFile & " --run=eip7702 /path/to/blockchain_tests/"

  var
    fastEnabled = false
    jsonEnabled = false
    runFilter = ""
    workers = 1
    inputPath = ""

  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case p.key.toLowerAscii
      of "fast":
        fastEnabled = true
      of "json":
        jsonEnabled = true
      of "run":
        runFilter = p.val
      of "workers":
        workers = parseInt(p.val)
      of "help", "h":
        printUsage()
        quit(QuitSuccess)
      else:
        echo "Unknown option: ", p.key
        printUsage()
        quit(QuitFailure)
    of cmdArgument:
      inputPath = p.key

  if inputPath.len == 0:
    printUsage()
    quit(QuitFailure)

  var files = collectJsonFiles(inputPath)

  if runFilter.len > 0:
    var filtered: seq[string]
    for f in files:
      if runFilter in f:
        filtered.add(f)
    files = filtered

  if files.len == 0:
    echo "No matching .json files found."
    quit(QuitFailure)

  type FileResult = object
    path: string
    pass: bool

  var
    results: seq[TestResult]
    passCount = 0
    failCount = 0

  if workers > 1:
    discard workers  # TODO: in-process parallelism requires GC-safe procs

  for f in files:
    if jsonEnabled:
      # Per-test results for JSON output
      let fixture = parseFixture(f, BlockchainFixture)
      for unit in fixture.units:
        let header = unit.unit.genesisBlockHeader.to(Header)
        if fastEnabled:
          try:
            let
              memDB = newCoreDbRef DefaultDbMemory
              baseTx = memDB.baseTxFrame()
              ledger = LedgerRef.init(baseTx)
              config = getChainConfig(unit.unit.network)
            config.chainId = unit.unit.config.chainid
            config.blobSchedule = unit.unit.config.blobSchedule
            setupLedger(unit.unit.pre, ledger)
            ledger.persist()
            let persistRes = baseTx.persistHeaderAndSetHead(header)
            if persistRes.isErr:
              inc failCount
              results.add(TestResult(name: unit.name, pass: false,
                error: "persist genesis: " & persistRes.error))
              continue
            let com = CommonRef.new(memDB, config)
            let res = runTestFast(com, header, baseTx, unit.unit)
            if res.isOk:
              inc passCount
              results.add(TestResult(name: unit.name, pass: true, error: ""))
            else:
              inc failCount
              results.add(TestResult(name: unit.name, pass: false, error: res.error))
          except CatchableError as e:
            inc failCount
            results.add(TestResult(name: unit.name, pass: false, error: e.msg))
        else:
          let env = prepareEnv(unit.unit, header, rpcEnabled = false)
          let res = waitFor env.runTest(unit.unit)
          if res.isOk:
            inc passCount
            results.add(TestResult(name: unit.name, pass: true, error: ""))
          else:
            inc failCount
            results.add(TestResult(name: unit.name, pass: false, error: res.error))
          env.close()
    else:
      let pass = if fastEnabled: processFileFast(f)
                 else: processFile(f)
      let rel = if dirExists(inputPath):
                  f.relativePath(inputPath)
                else:
                  f.splitPath().tail
      if pass:
        inc passCount
        echo "PASS: ", rel
      else:
        inc failCount
        echo "FAIL: ", rel

  if jsonEnabled:
    var arr = newJArray()
    for r in results:
      arr.add(%*{"name": r.name, "pass": r.pass, "error": r.error})
    echo $arr
  else:
    echo ""
    echo "Total: ", files.len, " | Passed: ", passCount,
      " | Failed: ", failCount

  if failCount > 0:
    quit(QuitFailure)
