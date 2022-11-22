import
  std/[json, strutils, sets, tables, options],
  chronicles,
  eth/[common, keys],
  stew/[results, byteutils],
  stint,
  eth/trie/[db, trie_defs],
  ../../nimbus/[forks, vm_types, chain_config, vm_state],
  ../../nimbus/db/[db_chain, accounts_cache],
  ../../nimbus/transaction,
  ../../nimbus/p2p/executor,
  "."/[config, helpers]

type
  StateContext = object
    name: string
    header: BlockHeader
    tx: Transaction
    expectedHash: Hash256
    expectedLogs: Hash256
    fork: Fork
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
    fork : string
    error: string
    state: StateDump

proc extractNameAndFixture(ctx: var StateContext, n: JsonNode): JsonNode =
  for label, child in n:
    result = child
    ctx.name = label
    return
  doAssert(false, "unreachable")

proc parseTx(txData, index: JsonNode): Transaction =
  let
    dataIndex = index["data"].getInt
    gasIndex  = index["gas"].getInt
    valIndex  = index["value"].getInt
  parseTx(txData, dataIndex, gasIndex, valIndex)

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

proc verifyResult(ctx: var StateContext, vmState: BaseVMState) =
  ctx.error = ""
  let obtainedHash = vmState.readOnlyStateDB.rootHash
  if obtainedHash != ctx.expectedHash:
    ctx.error = "post state root mismatch: got $1, want $2" %
      [$obtainedHash, $ctx.expectedHash]
    return

  let logEntries = vmState.getAndClearLogEntries()
  let actualLogsHash = rlpHash(logEntries)
  if actualLogsHash != ctx.expectedLogs:
    ctx.error = "post state log hash mismatch: got $1, want $2" %
      [$actualLogsHash, $ctx.expectedLogs]
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

proc writeTraceToStderr(vmState: BaseVMState, pretty: bool) =
  let trace = vmState.getTracingResult()
  if pretty:
    stderr.writeLine(trace.pretty)
  else:
    let logs = trace["structLogs"]
    trace.delete("structLogs")
    for x in logs:
      stderr.writeLine($x)
    stderr.writeLine($trace)

proc runExecution(ctx: var StateContext, conf: StateConf, pre: JsonNode): StateResult =
  let
    chainParams = NetworkParams(config: chainConfigForNetwork(MainNet))
    chainDB = newBaseChainDB(newMemoryDB(), pruneTrie = false, params = chainParams)
    parent  = BlockHeader(stateRoot: emptyRlpHash)

  # set total difficulty
  chainDB.setScore(parent.blockHash, 0.u256)

  if ctx.fork >= FkParis:
    chainDB.config.terminalTotalDifficulty = some(0.u256)

  let vmState = BaseVMState.new(
    parent      = parent,
    header      = ctx.header,
    chainDB     = chainDB,
    tracerFlags = ctx.tracerFlags,
    pruneTrie   = chainDB.pruneTrie)

  var gasUsed: GasInt
  let sender = ctx.tx.getSender()

  vmState.mutateStateDB:
    setupStateDB(pre, db)
    db.persist() # settle accounts storage

  defer:
    ctx.verifyResult(vmState)
    result = StateResult(
      name : ctx.name,
      pass : ctx.error.len == 0,
      fork : toString(ctx.fork),
      error: ctx.error
    )
    if conf.dumpEnabled:
      result.state = dumpState(vmState)
    if conf.jsonEnabled:
      writeTraceToStderr(vmState, conf.pretty)

  let rc = vmState.processTransaction(
                ctx.tx, sender, ctx.header, ctx.fork)
  if rc.isOk:
    gasUsed = rc.value

  let miner = ctx.header.coinbase
  if miner in vmState.selfDestructs:
    vmState.mutateStateDB:
      db.addBalance(miner, 0.u256)
      if ctx.fork >= FkSpurious:
        if db.isEmptyAccount(miner):
          db.deleteAccount(miner)
      db.persist()

proc toTracerFlags(conf: Stateconf): set[TracerFlags] =
  result = {
    TracerFlags.DisableStateDiff,
    TracerFlags.EnableTracing
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
    let fork = parseFork(forkName)
    doAssert(fork.isSome, "unsupported fork: " & forkName)
    ctx.fork = fork.get()
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
  proc toLogLevel(v: int): LogLevel =
    case v
    of 1: LogLevel.ERROR
    of 2: LogLevel.WARN
    of 3: LogLevel.INFO
    of 4: LogLevel.DEBUG
    of 5: LogLevel.TRACE
    else: LogLevel.NONE

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
