# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strutils, tables, json, os, sets],
  ./test_helpers, ./test_allowed_to_fail,
  ../execution_chain/core/executor, test_config,
  ../execution_chain/transaction,
  ../execution_chain/[evm/state, evm/types],
  ../execution_chain/db/ledger,
  ../execution_chain/common/common,
  ../execution_chain/utils/[utils, debug],
  ../execution_chain/evm/tracer/legacy_tracer,
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../tools/common/state_clearing,
  eth/common/transaction_utils,
  unittest2,
  stew/byteutils,
  results

type
  TestCtx = object
    name: string
    parent: Header
    header: Header
    pre: JsonNode
    tx: Transaction
    expectedHash: Hash32
    expectedLogs: Hash32
    chainConfig: ChainConfig
    debugMode: bool
    trace: bool
    index: int
    subFixture: int
    fork: string

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

method getAncestorHash*(vmState: BaseVMState; blockNumber: BlockNumber): Hash32 =
  if blockNumber >= vmState.blockNumber:
    return default(Hash32)
  elif blockNumber < 0:
    return default(Hash32)
  elif blockNumber < vmState.blockNumber - 256:
    return default(Hash32)
  else:
    return keccak256(toBytes($blockNumber))

func normalizeFileName(x: string): string =
  const invalidChars = ['/', '\\', '?', '%', '*', ':', '|', '"', '<', '>', ',', ';', '=']
  result = newStringOfCap(x.len)
  for c in x:
    if c in invalidChars: result.add '_'
    else: result.add c

proc dumpDebugData(ctx: TestCtx, vmState: BaseVMState, gasUsed: GasInt, success: bool) =
  let tracerInst = LegacyTracer(vmState.tracer)
  let tracingResult = if ctx.trace: tracerInst.getTracingResult() else: %[]
  let debugData = %{
    "gasUsed": %gasUsed,
    "structLogs": tracingResult,
    "accounts": vmState.dumpAccounts()
  }
  let status = if success: "_success" else: "_failed"
  let fileName = normalizeFileName(ctx.name)
  writeFile(fileName & "_" & $ctx.subFixture & "_" &
    ctx.fork & "_" & $ctx.index & status & ".json", debugData.pretty())

proc testFixtureIndexes(ctx: var TestCtx, testStatusIMPL: var TestStatus) =
  let
    com    = CommonRef.new(newCoreDbRef DefaultDbMemory, nil, ctx.chainConfig)
    parent = Header(stateRoot: emptyRoot)
    tracer = if ctx.trace:
               newLegacyTracer({})
             else:
               LegacyTracer(nil)

    vmState = BaseVMState.new(
      parent = parent,
      header = ctx.header,
      com    = com,
      txFrame = com.db.baseTxFrame(),
      tracer = tracer,
      storeSlotHash = ctx.trace,
    )

    sender = ctx.tx.recoverSender().expect("valid signature")

  vmState.mutateLedger:
    setupLedger(ctx.pre, db)

    # this is an important step when using `db/ledger`
    # it will affect the account storage's location
    # during the next call to `getComittedStorage`
    db.persist()

  let
    rc = vmState.processTransaction(
                ctx.tx, sender, ctx.header)
    callResult = if rc.isOk:
                   rc.value
                 else:
                   LogResult()

  let miner = ctx.header.coinbase
  coinbaseStateClearing(vmState, miner)

  block post:
    let obtainedHash = vmState.readOnlyLedger.getStateRoot()
    check obtainedHash == ctx.expectedHash
    let actualLogsHash = computeRlpHash(callResult.logEntries)
    check(ctx.expectedLogs == actualLogsHash)
    if ctx.debugMode:
      let success = ctx.expectedLogs == actualLogsHash and obtainedHash == ctx.expectedHash
      ctx.dumpDebugData(vmState, callResult.gasUsed, success)

proc testSubFixture(ctx: var TestCtx, fixture: JsonNode, testStatusIMPL: var TestStatus,
                 trace = false, debugMode = false) =
  ctx.pre    = fixture["pre"]
  ctx.parent = parseParentHeader(fixture["env"])
  ctx.header = parseHeader(fixture["env"])
  ctx.trace  = trace
  ctx.debugMode = debugMode

  let
    post   = fixture["post"]
    txData = fixture["transaction"]
    conf   = getConfiguration()

  template prepareFork(forkName: string) =
    try:
      ctx.chainConfig = getChainConfig(forkName)
    except ValueError as ex:
      debugEcho ex.msg
      testStatusIMPL = TestStatus.FAILED
      return

  template runSubTest(subTest: JsonNode) =
    ctx.expectedHash = Hash32.fromJson(subTest["hash"])
    ctx.expectedLogs = Hash32.fromJson(subTest["logs"])
    ctx.tx = parseTx(txData, subTest["indexes"])
    ctx.testFixtureIndexes(testStatusIMPL)

  if conf.fork.len > 0:
    if not post.hasKey(conf.fork):
      debugEcho "selected fork not available: " & conf.fork
      return

    ctx.fork = conf.fork
    let forkData = post[conf.fork]
    prepareFork(conf.fork)
    if conf.index.isNone:
      for subTest in forkData:
        runSubTest(subTest)
        inc ctx.index
    else:
      ctx.index = conf.index.get()
      if ctx.index > forkData.len or ctx.index < 0:
        debugEcho "selected index out of range(0-$1), requested $2" %
          [$forkData.len, $ctx.index]
        return

      let subTest = forkData[ctx.index]
      runSubTest(subTest)
  else:
    for forkName, forkData in post:
      prepareFork(forkName)
      ctx.fork = forkName
      ctx.index = 0
      for subTest in forkData:
        runSubTest(subTest)
        inc ctx.index

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus,
                 trace = false, debugMode = false) =
  let
    conf = getConfiguration()

  var
    ctx: TestCtx
    subFixture = 0

  for label, child in fixtures:
    ctx.name = label
    ctx.subFixture = subFixture
    inc subFixture
    if conf.subFixture.isSome and conf.subFixture.get != ctx.subFixture:
      continue
    testSubFixture(ctx, child, testStatusIMPL, trace, debugMode)

proc generalStateJsonMain*(debugMode = false) =
  const
    newFolder = "eest_static/state_tests"

  let config = getConfiguration()
  if config.testSubject == "" or not debugMode:
    # run all test fixtures
    suite "new generalstate json tests: eest_static":
      jsonTest(newFolder, "GeneralStateTests", testFixture, skipNewGSTTests)

    suite "new generalstate json tests: eest_stable":
      jsonTest("eest_stable/state_tests", "GeneralStateTests", testFixture, skipNewGSTTests)

    suite "new generalstate json tests: eest_develop":
      jsonTest("eest_develop/state_tests", "GeneralStateTests", testFixture, skipNewGSTTests)

    suite "new generalstate json tests: eest_devnet":
      jsonTest("eest_devnet/state_tests", "GeneralStateTests", testFixture, skipNewGSTTests)

  else:
    # execute single test in debug mode
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)
    
    let path = "tests" / "fixtures" / newFolder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, config.trace, true)

when isMainModule:
  var message: string

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  generalStateJsonMain(true)
else:
  generalStateJsonMain(false)
