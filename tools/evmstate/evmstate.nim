# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
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
  beacon_chain/process_state,
  stew/byteutils,
  results,
  stint,
  ../../execution_chain/[evm/types, evm/state],
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/transaction,
  ../../execution_chain/core/executor,
  ../../execution_chain/common/common,
  ../../execution_chain/evm/tracer/json_tracer,
  ../../execution_chain/utils/state_dump,
  ../common/helpers as chp,
  ../common/state_clearing,
   ./[config, helpers]

type
  StateContext = object
    name: string
    parent: Header
    header: Header
    tx: Transaction
    expectedHash: Hash32
    expectedLogs: Hash32
    postState: JsonNode
    forkStr: string
    chainConfig: ChainConfig
    index: int
    tracerFlags: set[TracerFlags]
    error: string

  StateResult* = object
    name* : string
    pass* : bool
    root* : Hash32
    fork* : string
    error*: string
    state*: StateDump
    postState*: JsonNode

  TestVMState = ref object of BaseVMState

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash32 =
  if blockNumber >= vmState.blockNumber:
    default(Hash32)
  elif blockNumber < 0:
    default(Hash32)
  elif (vmState.blockNumber > 256) and (blockNumber < vmState.blockNumber - 256):
    default(Hash32)
  else:
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
    if res.postState.isNil.not:
      z["postState"] = res.postState
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
    com     = CommonRef.new(newCoreDbRef DefaultDbMemory, ctx.chainConfig)
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

  vmState.mutateLedger:
    setupLedger(pre, ledger)
    ledger.persist(clearEmptyAccount = false) # settle accounts storage

  let sender = ctx.tx.recoverSender().valueOr:
    # Invalid signature, early exit
    let stateRoot = vmState.readOnlyLedger.getStateRoot()
    return StateResult(
      name : ctx.name,
      pass : true,
      root : stateRoot,
      fork : ctx.forkStr
    )

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
    if conf.postState:
      result.postState = ctx.postState
    if conf.jsonEnabled:
      writeRootHashToStderr(stateRoot)
    vmState.ledger.txFrame.dispose()
    vmState.dispose()
    com.db.close()

  try:
    let res = vmState.processTransaction(ctx.tx, sender)
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

proc parseTx(ctx: var StateContext, txData: JsonNode, subTest: JsonNode) =
  try:
    block txBytes:
      if not subTest.hasKey("txbytes"):
        break txBytes

      if subTest.hasKey("expectException"):
        let exceptionString = subTest["expectException"].getStr
        if "GASLIMIT_PRICE_PRODUCT_OVERFLOW" in exceptionString:
          # high_gas_price_paris.json cannot be rlp decoded
          # due to UInt256 gasPrice, while Nimbus tx gasPrice
          # field is uint64.
          # high_gas_price_paris.json can be decoded by parseTx.
          break txBytes
        if "NONCE_IS_MAX" in exceptionString:
          break txBytes

      let rlpBytes = hexToSeqByte(subTest["txbytes"].getStr)
      ctx.tx = rlp.decode(rlpBytes, Transaction)
      return

    if txData.hasKey("secretKey"):
      ctx.tx = parseTx(txData, subTest["indexes"])
      return

    doAssert(false, "Unsupported fixture format")
  except KeyError as exc:
    doAssert(false, exc.msg)
  except RlpError as exc:
    doAssert(false, exc.msg)

proc executeTest(stateRes: var seq[StateResult], name: string, n: JsonNode, conf: StateConf): bool =
  var
    ctx = StateContext(
      name: name,
    )

  let
    txData  = n["transaction"]
    post    = n["post"]
    pre     = n["pre"]

  ctx.parent = parseParentHeader(n["env"])
  ctx.header = parseHeader(n["env"])

  if conf.debugEnabled or conf.jsonEnabled:
    ctx.tracerFlags = toTracerFlags(conf)

  var
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
    if subTest.hasKey("state"):
      ctx.postState  = subTest["state"]
    ctx.parseTx(txData, subTest)
    let res = ctx.runExecution(conf, pre)
    stateRes.add res
    hasError = hasError or ctx.hasError

  if conf.fork.len > 0:
    if not post.hasKey(conf.fork):
      stdout.writeLine("selected fork not available: " & conf.fork)
      return false

    let forkData = post[conf.fork]
    prepareFork(conf.fork)
    if conf.subIndex.isNone:
      for subTest in forkData:
        runSubTest(subTest)
    else:
      let index = conf.subIndex.get()
      if index > forkData.len or index < 0:
        stdout.writeLine("selected sub index out of range(0-$1), requested $2" %
          [$forkData.len, $index])
        return false
      let subTest = forkData[index]
      runSubTest(subTest)
  else:
    for forkName, forkData in post:
      prepareFork(forkName)
      for subTest in forkData:
        runSubTest(subTest)

  not hasError

proc prepareAndRun*(inputFile: string, conf: StateConf, T: type): T =
  let
    fixture = json.parseFile(inputFile)

  var
    noError = true
    stateRes = newSeqOfCap[StateResult](fixture.len)

  if conf.index.isSome:
    let
      index = conf.index.get()

    var
      idx = 0
      found = false

    for name, node in pairs(fixture):
      if idx == index:
        noError = noError and executeTest(stateRes, name, node, conf)
        found = true
      inc idx

    if not found:
      stdout.writeLine("selected index out of range(0-$1), requested $2" %
        [$idx, $index])
  else:
    for name, node in pairs(fixture):
      noError = noError and executeTest(stateRes, name, node, conf)

  when T is bool:
    if conf.disableOutput:
      if not noError and conf.enableError:
        writeResultToStdout(stateRes)
    else:
      writeResultToStdout(stateRes)

    noError
  else:
    move(stateRes)

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

proc evmStateMain*() =
  # https://github.com/status-im/nimbus-eth1/issues/3131
  setStdIoUnbuffered()

  let conf = StateConf.init()
  when defined(chronicles_runtime_filtering):
    setVerbosity(conf.verbosity)

  if conf.inputFile.len > 0:
    if not prepareAndRun(conf.inputFile, conf, bool):
      quit(QuitFailure)
  else:
    ProcessState.setupStopHandlers()
    var noError = true
    for inputFile in lines(stdin):
      if (let reason = ProcessState.stopping(); reason.isSome()):
        echo "Shutting down, reason = ", reason[]
        break
      let res = prepareAndRun(inputFile, conf, bool)
      noError = noError and res
    if not noError:
      quit(QuitFailure)

when isMainModule:
  evmStateMain()
