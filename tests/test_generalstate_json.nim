# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strutils, tables, json, os, sets, options],
  ./test_helpers, ./test_allowed_to_fail,
  ../nimbus/core/executor, test_config,
  ../nimbus/transaction,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/db/ledger,
  ../nimbus/common/common,
  ../nimbus/utils/[utils, debug],
  ../nimbus/evm/tracer/legacy_tracer,
  ../nimbus/core/eip4844,
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../tools/common/state_clearing,
  eth/trie/trie_defs,
  unittest2,
  stew/[results, byteutils]

type
  TestCtx = object
    name: string
    parent: BlockHeader
    header: BlockHeader
    pre: JsonNode
    tx: Transaction
    expectedHash: Hash256
    expectedLogs: Hash256
    chainConfig: ChainConfig
    debugMode: bool
    trace: bool
    index: int
    fork: string

var
  trustedSetupLoaded = false

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

method getAncestorHash*(vmState: BaseVMState; blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  if blockNumber >= vmState.blockNumber:
    return
  elif blockNumber < 0:
    return
  elif blockNumber < vmState.blockNumber - 256:
    return
  else:
    return keccakHash(toBytes($blockNumber))

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
  writeFile(fileName & "_" & ctx.fork & "_" & $ctx.index & status & ".json", debugData.pretty())

proc testFixtureIndexes(ctx: var TestCtx, testStatusIMPL: var TestStatus) =
  let
    com    = CommonRef.new(newCoreDbRef DefaultDbMemory, ctx.chainConfig)
    parent = BlockHeader(stateRoot: emptyRlpHash)
    tracer = if ctx.trace:
               newLegacyTracer({})
             else:
               LegacyTracer(nil)

  if com.isCancunOrLater(ctx.header.timestamp):
    if not trustedSetupLoaded:
      let res = loadKzgTrustedSetup()
      if res.isErr:
        echo "FATAL: ", res.error
        quit(QuitFailure)
      trustedSetupLoaded = true

  let vmState = BaseVMState.new(
      parent = parent,
      header = ctx.header,
      com    = com,
      tracer = tracer,
    )

  var gasUsed: GasInt
  let sender = ctx.tx.getSender()
  let fork = com.toEVMFork(ctx.header.forkDeterminationInfo)

  vmState.mutateStateDB:
    setupStateDB(ctx.pre, db)

    # this is an important step when using `db/ledger`
    # it will affect the account storage's location
    # during the next call to `getComittedStorage`
    db.persist()

  let rc = vmState.processTransaction(
                ctx.tx, sender, ctx.header, fork)
  if rc.isOk:
    gasUsed = rc.value

  let miner = ctx.header.coinbase
  coinbaseStateClearing(vmState, miner, fork)

  block post:
    let obtainedHash = vmState.readOnlyStateDB.rootHash
    check obtainedHash == ctx.expectedHash
    let logEntries = vmState.getAndClearLogEntries()
    let actualLogsHash = rlpHash(logEntries)
    check(ctx.expectedLogs == actualLogsHash)
    if ctx.debugMode:
      let success = ctx.expectedLogs == actualLogsHash and obtainedHash == ctx.expectedHash
      ctx.dumpDebugData(vmState, gasUsed, success)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus,
                 trace = false, debugMode = false) =
  var ctx: TestCtx
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    ctx.name = label
    break

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
      testStatusIMPL = TestStatus.Failed
      return

  template runSubTest(subTest: JsonNode) =
    ctx.expectedHash = Hash256.fromJson(subTest["hash"])
    ctx.expectedLogs = Hash256.fromJson(subTest["logs"])
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

proc generalStateJsonMain*(debugMode = false) =
  const
    legacyFolder = "eth_tests/LegacyTests/Constantinople/GeneralStateTests"
    newFolder = "eth_tests/GeneralStateTests"
    #newFolder = "eth_tests/EIPTests/StateTests"

  let config = getConfiguration()
  if config.testSubject == "" or not debugMode:
    # run all test fixtures
    if config.legacy:
      suite "generalstate json tests":
        jsonTest(legacyFolder, "GeneralStateTests", testFixture, skipGSTTests)
    else:
      suite "new generalstate json tests":
        jsonTest(newFolder, "newGeneralStateTests", testFixture, skipNewGSTTests)
  else:
    # execute single test in debug mode
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: legacyFolder else: newFolder
    let path = "tests" / "fixtures" / folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, config.trace, true)

when isMainModule:
  import std/times
  var message: string

  let start = getTime()

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  generalStateJsonMain(true)
  let elpd = getTime() - start
  echo "TIME: ", elpd
