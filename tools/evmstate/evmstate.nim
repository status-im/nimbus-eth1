# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[json, strutils, sets, tables, options, streams],
  chronicles,
  eth/common/keys,
  eth/common/transaction_utils,
  beacon_chain/process_state,
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

  StateResult* = ref object
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
    ctx.error = "post state root mismatch: got " &
      ($obtainedHash).toLowerAscii &
      ", want " &
      $ctx.expectedHash
    return

  let actualLogsHash = computeRlpHash(callResult.logEntries)
  if actualLogsHash != ctx.expectedLogs:
    ctx.error = "post state log hash mismatch: got " &
      ($actualLogsHash).toLowerAscii &
      ", want " &
      $ctx.expectedLogs
    return

proc writeResultToStdout(stateRes: seq[StateResult]): Result[void, string] =
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

  try:
    stdout.write(n.pretty)
    stdout.write("\n")
    ok()
  except IOError as exc:
    err(exc.msg)

proc writeRootHashToStderr(stateRoot: Hash32): Result[void, string] =
  let stateRoot = %{
    "stateRoot": %(stateRoot)
  }
  try:
    stderr.writeLine($stateRoot)
    ok()
  except IOError as exc:
    err(exc.msg)

func sanitizeHeader(com: CommonRef, h: Header): Header =
  result = h

  if not com.isLondonOrLater(h.number, h.timestamp):
    result.baseFeePerGas = Opt.none(UInt256)

  if not com.isShanghaiOrLater(h.timestamp):
    result.withdrawalsRoot = Opt.none(Hash32)

  if not com.isCancunOrLater(h.timestamp):
    result.blobGasUsed = Opt.none(uint64)
    result.excessBlobGas = Opt.none(uint64)
    result.parentBeaconBlockRoot = Opt.none(Hash32)

  if not com.isPragueOrLater(h.timestamp):
    result.requestsHash = Opt.none(Hash32)

  if not com.isAmsterdamOrLater(h.timestamp):
    result.blockAccessListHash = Opt.none(Hash32)
    result.slotNumber = Opt.none(uint64)

proc runExecution(ctx: var StateContext, conf: StateConf, pre: GenesisAlloc): Result[StateResult, string] =
  let
    com     = CommonRef.new(newCoreDbRef DefaultDbMemory, ctx.chainConfig)
    stream  = newFileStream(stderr)
    tracer  = if conf.jsonEnabled:
                newJsonTracer(stream, ctx.tracerFlags, conf.pretty)
              else:
                JsonTracer(nil)

  let vmState = TestVMState()
  vmState.init(
    parent  = com.sanitizeHeader(ctx.parent),
    header  = com.sanitizeHeader(ctx.header),
    com     = com,
    txFrame = com.db.baseTxFrame(),
    tracer  = tracer)

  defer:
    vmState.ledger.txFrame.dispose()
    vmState.dispose()
    com.db.close()

  vmState.mutateLedger:
    setupLedger(pre, ledger)
    ledger.persist(clearEmptyAccount = false) # settle accounts storage

  let sender = ctx.tx.recoverSender().valueOr:
    # Invalid signature, early exit
    let stateRoot = vmState.readOnlyLedger.getStateRoot()
    return ok(StateResult(
      name : ctx.name,
      pass : true,
      root : stateRoot,
      fork : ctx.forkStr
    ))

  let callResult = vmState.processTransaction(ctx.tx, sender).valueOr(LogResult())
  coinbaseStateClearing(vmState, ctx.header.coinbase)

  let stateRoot = vmState.readOnlyLedger.getStateRoot()
  ctx.verifyResult(vmState, stateRoot, callResult)

  let res = StateResult(
    name : ctx.name,
    pass : ctx.error.len == 0,
    root : stateRoot,
    fork : ctx.forkStr,
    error: ctx.error
  )

  if conf.dumpEnabled:
    res.state = dumpState(vmState.ledger)
  if conf.postState:
    res.postState = ctx.postState
  if conf.jsonEnabled:
    ? writeRootHashToStderr(stateRoot)

  ok(res)

proc toTracerFlags(conf: StateConf): set[TracerFlags] =
  result = {
    TracerFlags.DisableStateDiff
  }

  if conf.disableMemory    : result.incl TracerFlags.DisableMemory
  if conf.disableStack     : result.incl TracerFlags.DisableStack
  if conf.disableReturnData: result.incl TracerFlags.DisableReturnData
  if conf.disableStorage   : result.incl TracerFlags.DisableStorage

proc parseTx(ctx: var StateContext, txo: Txo, subTest: SubTest): Result[void, string] =
  try:
    if txo.secretKey.isSome:
      ctx.tx = ? parseTx(txo, subTest.indexes, ctx.chainConfig.eip155Block.isSome)
      return ok()

    if subTest.txbytes.len > 0:
      ctx.tx = rlp.decode(subTest.txbytes, Transaction)
      return ok()

    return err("Unsupported fixture format")
  #except KeyError as exc:
  #  return err(exc.msg)
  except RlpError as exc:
    return err(exc.msg)

func prepareFork(ctx: var StateContext, forkName: string): Result[void, string] =
  ctx.forkStr = forkName
  ctx.chainConfig = ? getChainConfig(forkName)
  inc ctx.index
  ok()

proc runSubTest(ctx: var StateContext,
                unit: StateUnit,
                subTest: SubTest,
                conf: StateConf): Result[StateResult, string] =
  ctx.expectedHash = subTest.hash
  ctx.expectedLogs = subTest.logs
  if subTest.state.isNil.not:
    ctx.postState  = subTest.state
  ? ctx.parseTx(unit.txo, subTest)
  ctx.runExecution(conf, unit.pre)

proc executeTest(resList: var seq[StateResult], unit: StateUnit, conf: StateConf): Result[void, string] =
  var
    ctx = StateContext(
      index : 0,
      name  : unit.name,
      parent: ? parseParentHeader(unit.env),
      header: ? parseHeader(unit.env),
    )

  if conf.debugEnabled or conf.jsonEnabled:
    ctx.tracerFlags = toTracerFlags(conf)

  if conf.fork.len == 0:
    for forkName, subTests in unit.post:
      ? ctx.prepareFork(forkName)
      for subTest in subTests.subs:
        let res = ? ctx.runSubTest(unit, subTest, conf)
        resList.add res
    return ok()

  unit.post.withValue(conf.fork, val):
    let subTests = val[]
    ? ctx.prepareFork(conf.fork)

    if conf.subIndex.isNone:
      for subTest in subTests.subs:
        let res = ? ctx.runSubTest(unit, subTest, conf)
        resList.add res
    else:
      let index = conf.subIndex.get()
      if index > subTests.subs.len or index < 0:
        return err("selected sub index out of range(0-" &
          $subTests.subs.len & "), requested " & $index)
      let res = ? ctx.runSubTest(unit, subTests.subs[index], conf)
      resList.add res
    return ok()
  do:
    return err("selected fork not available: " & conf.fork)

func noError(list: openArray[StateResult]): bool =
  for x in list:
    if x.error.len > 0: return false
  true

proc prepareAndRun*(inputFile: string, conf: StateConf, T: type): Result[T, string] =
  let
    fixture = ? parseFixture(inputFile)

  var
    noError = true
    stateRes = newSeqOfCap[StateResult](fixture.units.len)

  if conf.index.isNone:
    for unit in fixture.units:
      ? executeTest(stateRes, unit, conf)
    noError = stateRes.noError
  else:
    let
      index = conf.index.get()
    var
      found = false

    for idx, unit in fixture.units:
      if idx == index:
        ? executeTest(stateRes, unit, conf)
        found = true
    noError = stateRes.noError

    if not found:
      return err("selected index out of range(0-" &
        $fixture.units.len &
        "), requested " & $index)

  when T is bool:
    if conf.disableOutput:
      if not noError and conf.enableError:
        ? writeResultToStdout(stateRes)
    else:
      ? writeResultToStdout(stateRes)

    ok(noError)
  else:
    ok(move(stateRes))

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

proc evmStateMain*() {.raises: [IOError].} =
  # https://github.com/status-im/nimbus-eth1/issues/3131
  setStdIoUnbuffered()

  let conf = try:
               StateConf.init()
             except CatchableError as exc:
               fatal "Configuration error", msg=exc.msg
               quit(QuitFailure)

  when defined(chronicles_runtime_filtering):
    setVerbosity(conf.verbosity)

  if conf.inputFile.len > 0:
    let res = prepareAndRun(conf.inputFile, conf, bool).valueOr:
      fatal "Error when running test",
        file=conf.inputFile,
        msg=error
      quit(QuitFailure)
    if not res:
      quit(QuitFailure)
  else:
    ProcessState.setupStopHandlers()
    var noError = true
    for inputFile in lines(stdin):
      if (let reason = ProcessState.stopping(); reason.isSome()):
        echo "Shutting down, reason = ", reason[]
        break
      let res = prepareAndRun(inputFile, conf, bool).valueOr:
        fatal "Error when running test",
          file=inputFile,
          msg=error
        quit(QuitFailure)
      noError = noError and res
    if not noError:
      quit(QuitFailure)

when isMainModule:
  evmStateMain()
