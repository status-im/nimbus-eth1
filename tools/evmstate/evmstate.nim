# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, sets, tables, options],
  chronicles,
  eth/keys,
  stew/[results, byteutils],
  stint,
  eth/trie/[trie_defs],
  ../../nimbus/[vm_types, vm_state],
  ../../nimbus/db/accounts_cache,
  ../../nimbus/transaction,
  ../../nimbus/core/executor,
  ../../nimbus/common/common,
  ../common/helpers as chp,
  "."/[config, helpers],
  ../common/state_clearing

type
  StateContext = object
    name: string
    header: BlockHeader
    tx: Transaction
    expectedHash: Hash256
    expectedLogs: Hash256
    forkStr: string
    chainConfig: ChainConfig
    index: int
    tracerFlags: set[TracerFlags]
    error: string

  DumpAccount = ref object
    balance : UInt256
    nonce   : AccountNonce
    root    : Hash256
    codeHash: Hash256
    code    : Blob
    key     : Hash256
    storage : Table[UInt256, UInt256]

  StateDump = ref object
    root: Hash256
    accounts: Table[EthAddress, DumpAccount]

  StateResult = object
    name : string
    pass : bool
    root : Hash256
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

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  keccakHash(toBytes($blockNumber))

proc verifyResult(ctx: var StateContext, vmState: BaseVMState) =
  ctx.error = ""
  let obtainedHash = vmState.readOnlyStateDB.rootHash
  if obtainedHash != ctx.expectedHash:
    ctx.error = "post state root mismatch: got $1, want $2" %
      [($obtainedHash).toLowerAscii, $ctx.expectedHash]
    return

  let logEntries = vmState.getAndClearLogEntries()
  let actualLogsHash = rlpHash(logEntries)
  if actualLogsHash != ctx.expectedLogs:
    ctx.error = "post state log hash mismatch: got $1, want $2" %
      [($actualLogsHash).toLowerAscii, $ctx.expectedLogs]
    return

proc `%`(x: UInt256): JsonNode =
  %("0x" & x.toHex)

proc `%`(x: Blob): JsonNode =
  %("0x" & x.toHex)

proc `%`(x: Hash256): JsonNode =
  %("0x" & x.data.toHex)

proc `%`(x: AccountNonce): JsonNode =
  %("0x" & x.toHex)

proc `%`(x: Table[UInt256, UInt256]): JsonNode =
  result = newJObject()
  for k, v in x:
    result["0x" & k.toHex] = %(v)

proc `%`(x: DumpAccount): JsonNode =
  result = %{
    "balance" : %(x.balance),
    "nonce"   : %(x.nonce),
    "root"    : %(x.root),
    "codeHash": %(x.codeHash),
    "code"    : %(x.code),
    "key"     : %(x.key)
  }
  if x.storage.len > 0:
    result["storage"] = %(x.storage)

proc `%`(x: Table[EthAddress, DumpAccount]): JsonNode =
  result = newJObject()
  for k, v in x:
    result["0x" & k.toHex] = %(v)

proc `%`(x: StateDump): JsonNode =
  result = %{
    "root": %(x.root),
    "accounts": %(x.accounts)
  }

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

proc dumpAccounts(db: AccountsCache): Table[EthAddress, DumpAccount] =
  for accAddr in db.addresses():
    let acc = DumpAccount(
      balance : db.getBalance(accAddr),
      nonce   : db.getNonce(accAddr),
      root    : db.getStorageRoot(accAddr),
      codeHash: db.getCodeHash(accAddr),
      code    : db.getCode(accAddr),
      key     : keccakHash(accAddr)
    )
    for k, v in db.storage(accAddr):
      acc.storage[k] = v
    result[accAddr] = acc

proc dumpState(vmState: BaseVMState): StateDump =
  StateDump(
    root: vmState.readOnlyStateDB.rootHash,
    accounts: dumpAccounts(vmState.stateDB)
  )

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeHexInt(x: SomeInteger): JsonNode =
  %("0x" & x.toHex.stripLeadingZeros.toLowerAscii)

proc writeTraceToStderr(vmState: BaseVMState, pretty: bool) =
  let trace = vmState.getTracingResult()
  trace["gasUsed"] = encodeHexInt(vmState.tracerGasUsed)
  trace.delete("gas")
  let stateRoot = %{
    "stateRoot": %(vmState.readOnlyStateDB.rootHash)
  }
  if pretty:
    stderr.writeLine(trace.pretty)
  else:
    let logs = trace["structLogs"]
    trace.delete("structLogs")
    for x in logs:
      if "error" in x:
        trace["error"] = x["error"]
        x.delete("error")
      stderr.writeLine($x)

    stderr.writeLine($trace)
    stderr.writeLine($stateRoot)

proc runExecution(ctx: var StateContext, conf: StateConf, pre: JsonNode): StateResult =
  let
    com     = CommonRef.new(newMemoryDB(), ctx.chainConfig, pruneTrie = false)
    parent  = BlockHeader(stateRoot: emptyRlpHash)
    fork    = com.toEVMFork(ctx.header.forkDeterminationInfoForHeader)

  let vmState = TestVMState()
  vmState.init(
    parent      = parent,
    header      = ctx.header,
    com         = com,
    tracerFlags = ctx.tracerFlags)

  var gasUsed: GasInt
  let sender = ctx.tx.getSender()

  vmState.mutateStateDB:
    setupStateDB(pre, db)
    db.persist(clearEmptyAccount = false, clearCache = false) # settle accounts storage

  defer:
    ctx.verifyResult(vmState)
    result = StateResult(
      name : ctx.name,
      pass : ctx.error.len == 0,
      root : vmState.stateDB.rootHash,
      fork : ctx.forkStr,
      error: ctx.error
    )
    if conf.dumpEnabled:
      result.state = dumpState(vmState)
    if conf.jsonEnabled:
      writeTraceToStderr(vmState, conf.pretty)

  let rc = vmState.processTransaction(
                ctx.tx, sender, ctx.header, fork)
  if rc.isOk:
    gasUsed = rc.value

  let miner = ctx.header.coinbase
  coinbaseStateClearing(vmState, miner, fork)

proc toTracerFlags(conf: Stateconf): set[TracerFlags] =
  result = {
    TracerFlags.DisableStateDiff,
    TracerFlags.EnableTracing,
    TracerFlags.GethCompatibility
  }

  if conf.disableMemory    : result.incl TracerFlags.DisableMemory
  if conf.disablestack     : result.incl TracerFlags.DisableStack
  if conf.disableReturnData: result.incl TracerFlags.DisableReturnData
  if conf.disableStorage   : result.incl TracerFlags.DisableStorage

template hasError(ctx: StateContext): bool =
  ctx.error.len > 0

proc prepareAndRun(ctx: var StateContext, conf: StateConf): bool =
  let
    fixture = json.parseFile(conf.inputFile)
    n       = ctx.extractNameAndFixture(fixture)
    txData  = n["transaction"]
    post    = n["post"]
    pre     = n["pre"]

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
    ctx.expectedHash = Hash256.fromJson(subTest["hash"])
    ctx.expectedLogs = Hash256.fromJson(subTest["logs"])
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
  let conf = StateConf.init()
  when defined(chronicles_runtime_filtering):
    setVerbosity(conf.verbosity)
  var ctx: StateContext
  if not ctx.prepareAndRun(conf):
    quit(QuitFailure)

main()
