# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, sets, tables, options, streams],
  chronicles,
  eth/common/keys,
  eth/common/transaction_utils,
  stew/byteutils,
  results,
  stint,
  ../../execution_chain/[evm/types, evm/state],
  ../../execution_chain/db/ledger,
  ../../execution_chain/transaction,
  ../../execution_chain/core/executor,
  ../../execution_chain/common/common,
  ../../execution_chain/evm/tracer/json_tracer,
  ../../execution_chain/utils/state_dump,
  ../common/helpers as chp,
  "."/[config, helpers],
  ../common/state_clearing

type
  StateContext = object
    name: string
    parent: Header
    header: Header
    tx: Transaction
    expectedHash: Hash32
    expectedLogs: Hash32
    forkStr: string
    chainConfig: ChainConfig
    index: int
    tracerFlags: set[TracerFlags]
    error: string

  StateResult = object
    name : string
    pass : bool
    root : Hash32
    fork : string
    error: string
    state: StateDump

  TestVMState = ref object of BaseVMState

proc extractNameAndFixture(ctx: var StateContext, n: JsonNode): JsonNode =
  for label, child in n:
    result = child
    ctx.name = label
    return
  doAssert(false, "unreachable")

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash32 =
  keccak256(toBytes($blockNumber))

proc verifyResult(ctx: var StateContext,
                  vmState: BaseVMState,
                  obtainedHash: Hash32,
                  callResult: LogResult) =
  ctx.error = ""
  if obtainedHash != ctx.expectedHash:
    ctx.error = "post state root mismatch: got $1, want $2" %
      [($obtainedHash).toLowerAscii, $ctx.expectedHash]
    return

  let actualLogsHash = computeRlpHash(callResult.logEntries)
  if actualLogsHash != ctx.expectedLogs:
    ctx.error = "post state log hash mismatch: got $1, want $2" %
      [($actualLogsHash).toLowerAscii, $ctx.expectedLogs]
    return

proc writeResultToStdout(stateRes: seq[StateResult]) =
  var n = newJArray()
  for res in stateRes:
    let z = %{
      "name" : %(res.name),
      "pass" : %(res.pass),
      "stateRoot" : %(res.root),
      "fork" : %(res.fork),
      "error": %(res.error)
    }
    if res.state.isNil.not:
      z["state"] = %(res.state)
    n.add(z)

  stdout.write(n.pretty)
  stdout.write("\n")

proc writeRootHashToStderr(stateRoot: Hash32) =
  let stateRoot = %{
    "stateRoot": %(stateRoot)
  }
  stderr.writeLine($stateRoot)

proc runExecution(ctx: var StateContext, conf: StateConf, pre: JsonNode): StateResult =
  let
    com     = CommonRef.new(newCoreDbRef DefaultDbMemory, nil, ctx.chainConfig)
    stream  = newFileStream(stderr)
    tracer  = if conf.jsonEnabled:
                newJsonTracer(stream, ctx.tracerFlags, conf.pretty)
              else:
                JsonTracer(nil)

  let vmState = TestVMState()
  vmState.init(
    parent = ctx.parent,
    header = ctx.header,
    com    = com,
    txFrame = com.db.baseTxFrame(),
    tracer = tracer)

  let sender = ctx.tx.recoverSender().expect("valid signature")

  vmState.mutateLedger:
    setupLedger(pre, db)
    db.persist(clearEmptyAccount = false) # settle accounts storage

  var callResult: LogResult
  defer:
    let stateRoot = vmState.readOnlyLedger.getStateRoot()
    ctx.verifyResult(vmState, stateRoot, callResult)
    result = StateResult(
      name : ctx.name,
      pass : ctx.error.len == 0,
      root : stateRoot,
      fork : ctx.forkStr,
      error: ctx.error
    )
    if conf.dumpEnabled:
      result.state = dumpState(vmState.ledger)
    if conf.jsonEnabled:
      writeRootHashToStderr(stateRoot)

  try:
    let res = vmState.processTransaction(
                   ctx.tx, sender, ctx.header)
    if res.isOk:
      callResult = res.value
    coinbaseStateClearing(vmState, ctx.header.coinbase)
  except CatchableError as ex:
    echo "FATAL: ", ex.msg
    quit(QuitFailure)
  except AssertionDefect as ex:
    echo "FATAL: ", ex.msg
    quit(QuitFailure)

proc toTracerFlags(conf: StateConf): set[TracerFlags] =
  result = {
    TracerFlags.DisableStateDiff
  }

  if conf.disableMemory    : result.incl TracerFlags.DisableMemory
  if conf.disableStack     : result.incl TracerFlags.DisableStack
  if conf.disableReturnData: result.incl TracerFlags.DisableReturnData
  if conf.disableStorage   : result.incl TracerFlags.DisableStorage

template hasError(ctx: StateContext): bool =
  ctx.error.len > 0

proc prepareAndRun(inputFile: string, conf: StateConf): bool =
  var
    ctx: StateContext

  let
    fixture = json.parseFile(inputFile)
    n       = ctx.extractNameAndFixture(fixture)
    txData  = n["transaction"]
    post    = n["post"]
    pre     = n["pre"]

  ctx.parent = parseParentHeader(n["env"])
  ctx.header = parseHeader(n["env"])

  if conf.debugEnabled or conf.jsonEnabled:
    ctx.tracerFlags = toTracerFlags(conf)

  var
    stateRes = newSeqOfCap[StateResult](post.len)
    index = 1
    hasError = false

  template prepareFork(forkName: string) =
    try:
      ctx.forkStr = forkName
      ctx.chainConfig = getChainConfig(forkName)
    except ValueError as ex:
      debugEcho ex.msg
      return false
    ctx.index = index
    inc index

  template runSubTest(subTest: JsonNode) =
    ctx.expectedHash = Hash32.fromJson(subTest["hash"])
    ctx.expectedLogs = Hash32.fromJson(subTest["logs"])
    ctx.tx = parseTx(txData, subTest["indexes"])
    let res = ctx.runExecution(conf, pre)
    stateRes.add res
    hasError = hasError or ctx.hasError

  if conf.fork.len > 0:
    if not post.hasKey(conf.fork):
      stdout.writeLine("selected fork not available: " & conf.fork)
      return false

    let forkData = post[conf.fork]
    prepareFork(conf.fork)
    if conf.index.isNone:
      for subTest in forkData:
        runSubTest(subTest)
    else:
      let index = conf.index.get()
      if index > forkData.len or index < 0:
        stdout.writeLine("selected index out of range(0-$1), requested $2" %
          [$forkData.len, $index])
        return false

      let subTest = forkData[index]
      runSubTest(subTest)
  else:
    for forkName, forkData in post:
      prepareFork(forkName)
      for subTest in forkData:
        runSubTest(subTest)

  writeResultToStdout(stateRes)
  not hasError

when defined(chronicles_runtime_filtering):
  type Lev = chronicles.LogLevel
  proc toLogLevel(v: int): Lev =
    case v
    of 1: Lev.ERROR
    of 2: Lev.WARN
    of 3: Lev.INFO
    of 4: Lev.DEBUG
    of 5: Lev.TRACE
    else: Lev.NONE

  proc setVerbosity(v: int) =
    let level = v.toLogLevel
    setLogLevel(level)

proc main() =
  # https://github.com/status-im/nimbus-eth1/issues/3131
  setStdIoUnbuffered()

  let conf = StateConf.init()
  when defined(chronicles_runtime_filtering):
    setVerbosity(conf.verbosity)

  if conf.inputFile.len > 0:
    if not prepareAndRun(conf.inputFile, conf):
      quit(QuitFailure)
  else:
    var noError = true
    for inputFile in lines(stdin):
      let res = prepareAndRun(inputFile, conf)
      noError = noError and res
    if not noError:
      quit(QuitFailure)

main()
