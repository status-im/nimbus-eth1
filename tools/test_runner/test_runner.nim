# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## `test_runner blocktest` and `test_runner enginetest`: run EEST blockchain
## and blockchain engine fixtures through Nimbus's block import and Engine API
## handler, following the client test runner interface in execution-specs
## (`docs/running_tests/consume/client_runners.md`). Results are one JSON
## array on stdout, everything else goes to stderr.
{.push raises: [].}

import
  std/[algorithm, cpuinfo, json, os, parseutils, sequtils, strutils, tables, typetraits],
  chronos,
  stew/byteutils,
  taskpools,
  kzg4844/kzg,
  json_rpc/rpcserver,
  json_serialization,
  web3/[conversions, eth_api_types, primitives],
  ../../execution_api/conversions,
  eth/common/[blocks_rlp, block_access_lists, block_access_lists_rlp, headers_rlp],
  ../../execution_chain/version_info,
  ../../execution_chain/rpc/engine_api,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/beacon/api_handler/[api_forkchoice, api_newpayload],
  ../../execution_chain/common/[common, genesis],
  ../../tests/eest/eest_parser,
  ../../tests/eest/bal_parser

import ../common/helpers as chp except HardFork

# Load eagerly: lazy loading is not thread safe.
discard loadTrustedSetupFromString(kzg.trustedSetup, 8)

type
  Mode = enum
    BlockTest
    EngineTest

  Options = object
    mode: Mode
    workers: int
    threads: int
    balSequential: bool
    balWithhold: bool
    balReport: bool

  Env = ref object
    chain: ForkedChainRef
    engine: BeaconEngineRef
    server: RpcServer
    kept: Table[Hash32, string]
      ## Blocks whose list the runner kept back, with the report's reason.

var
  work: Channel[string]
  results: Channel[string]
    ## "R" and a JSON array of one file's results, or "E" and why the file
    ## could not be run.

const usage = """Usage: test_runner blocktest|enginetest [options] PATH...

Runs every fixture in the files and directories given, in one process.

Options:
  --workers N       run fixture files on N threads (default 1)
  --threads N       background threads per worker for parallel execution (2+)
  --bal-sequential  run every block on the sequential executor
  --bal-withhold    (blocktest) execute without the fixture's access list
  --bal-report      print the executor chosen for each block on stderr
  --version         print the version and exit"""

proc versionLine(): string =
  "Nimbus-test-runner " & NimbusVersion & "-" & GitRevision

# ------------------------------------------------------------------------------
# Environment
# ------------------------------------------------------------------------------

proc prepareEnv(
    unit: UnitEnv, genesis: Header, opts: Options, taskpool: Taskpool
): Result[Env, string] =
  var config = getChainConfig(unit.network).valueOr:
    return err("unsupported fork " & unit.network & ": " & error)
  config.chainId = unit.config.chainid
  config.blobSchedule = unit.config.blobSchedule

  let memDB = newCoreDbRef(DefaultDbMemory, enableCaches = true)
  discard writeGenesisAlloc(unit.pre, memDB.baseTxFrame())

  let ledger = LedgerRef.init(memDB.baseTxFrame())
  ledger.txFrame.persistHeaderAndSetHead(genesis).isOkOr:
    return err("cannot store the genesis header: " & $error)

  let com = CommonRef.new(
    memDB,
    config,
    parallelSenderRecovery = true,
    optimisticStatePrefetch = true,
    balStatePrefetch = true,
    balParallelExecution = not opts.balSequential,
  )
  com.taskpool = taskpool
  com.db.mpt.taskpool = taskpool
  com.db.mpt.parallelStateRootComputation = true

  let env = Env(chain: ForkedChainRef.init(com))

  if opts.mode == EngineTest:
    env.engine = BeaconEngineRef.new(TxPoolRef.new(env.chain))
    env.server = RpcServer.new()
    setupEngineAPI(env.engine, env.server)

  ok(env)

proc close(env: Env) =
  if not env.engine.isNil:
    waitFor env.engine.stop()
  waitFor env.chain.flushBaseLoop()
  env.chain.com.db.close()

proc reportExecution(
    env: Env, opts: Options, number: uint64, hash: Hash32, timestamp: EthTime,
    hasList: bool,
) =
  ## With `--bal-report`, print the executor a block runs on, by the gates of
  ## `balParallelExecutionEnabled`, and the first gate that ruled parallel out.
  if not opts.balReport or number == 0:
    return
  let reason =
    if hash in env.kept:
      env.kept.getOrDefault(hash)
    else:
      when not compileOption("threads"):
        "no-threads"
      else:
        if opts.balSequential: "disabled"
        elif not hasList: "no-access-list"
        elif not env.chain.com.isAmsterdamOrLater(timestamp): "pre-amsterdam"
        else: ""
  let line = %*{
    "event": "balExecution",
    "block": number,
    "hash": hash.data.to0xHex(),
    "path": (if reason.len == 0: "parallel" else: "sequential"),
    "reason": reason,
  }
  try:
    stderr.write($line & "\n")
    stderr.flushFile()
  except IOError:
    discard

proc genesisHeader(unit: UnitEnv): Result[Header, string] =
  let header = unit.genesisBlockHeader.to(Header)
  if header.computeRlpHash != unit.genesisBlockHeader.hash:
    return err(
      "genesis hash mismatch, fixture: " & $unit.genesisBlockHeader.hash &
        ", computed: " & $header.computeRlpHash
    )
  ok(header)

proc rejection(index: int, hash: Opt[Hash32], error: string): JsonNode =
  result = %*{"index": index}
  if hash.isSome:
    result["hash"] = %hash.get.data.to0xHex()
  result["error"] = %error

proc fixtureResult(
    name, fork, error: string, rejections: seq[JsonNode]
): JsonNode =
  %*{
    "name": name,
    "pass": error.len == 0,
    "fork": fork,
    "error": error,
    "rejections": rejections,
  }

# ------------------------------------------------------------------------------
# Block tests
# ------------------------------------------------------------------------------

proc deliveredList(
    env: Env, blk: BlockDescNode, header: Header, opts: Options
): Opt[BlockAccessListRef] =
  ## The fixture's list for this block, attached when its hash matches the
  ## header's and dropped otherwise, as the interface asks.
  let node =
    if blk.blockAccessList.isNil.not:
      blk.blockAccessList
    elif blk.rlp_decoded.isSome and blk.rlp_decoded.value.blockAccessList.isNil.not:
      blk.rlp_decoded.value.blockAccessList
    else:
      return Opt.none(BlockAccessListRef)

  let hash = header.computeBlockHash
  if opts.balWithhold:
    env.kept[hash] = "withheld"
    return Opt.none(BlockAccessListRef)

  let bal = new BlockAccessList
  try:
    bal[] = balFromJson(node)
  except CatchableError:
    env.kept[hash] = "bad-access-list"
    return Opt.none(BlockAccessListRef)

  if header.blockAccessListHash != Opt.some(bal[].computeBlockAccessListHash()):
    env.kept[hash] = "bad-access-list"
    return Opt.none(BlockAccessListRef)

  Opt.some(bal)

proc runBlockTest(
    env: Env, unit: BlockchainUnitEnv, opts: Options, rejections: var seq[JsonNode]
): string =
  ## Import every block as beacon sync imports a block above finality; the
  ## first reason the fixture fails, or empty when it passes.
  var failure = ""
  template fail(msg: string) =
    if failure.len == 0:
      failure = msg

  for i, x in unit.blocks:
    let expectInvalid = x.expectException.len > 0
    let blk =
      try:
        rlp.decode(x.rlp, Block)
      except CatchableError as exc:
        rejections.add rejection(i, Opt.none(Hash32), exc.msg)
        if not expectInvalid:
          fail("block " & $i & " failed to decode: " & exc.msg)
        continue

    let
      hash = blk.header.computeBlockHash
      bal = env.deliveredList(x, blk.header, opts)
      res = waitFor noCancel env.chain.importBlock(blk, bal)
    env.reportExecution(
      opts, blk.header.number, hash, blk.header.timestamp, bal.isSome)
    if res.isErr:
      rejections.add rejection(i, Opt.some(hash), res.error.msg)
      if not expectInvalid:
        fail("block " & $i & " was rejected: " & res.error.msg)
    elif expectInvalid:
      fail("block " & $i & " was imported, but the fixture expects an exception")

  if failure.len > 0:
    return failure

  env.chain.forkChoice(unit.lastblockhash, zeroHash32).isOkOr:
    return "forkchoice to lastblockhash failed: " & error
  if env.chain.latestHash != unit.lastblockhash:
    return "head " & $env.chain.latestHash & " is not lastblockhash " &
      $unit.lastblockhash
  ""

proc runBlockUnit(
    unit: BlockchainUnitEnv, opts: Options, taskpool: Taskpool,
    rejections: var seq[JsonNode],
): string =
  let genesis = unit.genesisHeader().valueOr:
    return error
  let env = prepareEnv(unit, genesis, opts, taskpool).valueOr:
    return error
  result = env.runBlockTest(unit, opts, rejections)
  env.close()

when defined(windows):
  proc longPath(path: string): string =
    ## Windows opens a path longer than MAX_PATH only in its `\\?\` form.
    try:
      "\\\\?\\" & normalizedPath(absolutePath(path))
    except CatchableError:
      path

else:
  template longPath(path: string): string =
    path

template runFile(path: string, T: type, runUnit: untyped): string =
  ## A file that is not JSON cannot be run; a fixture in it that Nimbus cannot
  ## read, such as one for a fork it does not know, fails on its own.
  let fixtures =
    try:
      parseFile(longPath(path))
    except CatchableError as exc:
      return "E" & path & ": " & exc.msg
  if fixtures.kind != JObject:
    return "E" & path & ": not a JSON object of fixtures"

  var output = newJArray()
  for name, node in fixtures:
    var rejections: seq[JsonNode]
    let
      network = node{"network"}.getStr
      error =
        if getChainConfig(network).isErr:
          "unsupported fork " & network
        else:
          try:
            let unit = EthJson.decode($node, T)
            runUnit(unit, opts, taskpool, rejections)
          except CatchableError as exc:
            "cannot read the fixture: " & exc.msg
    output.add fixtureResult(name, network, error, rejections)
  "R" & $output

proc runBlockFile(path: string, opts: Options, taskpool: Taskpool): string =
  runFile(path, BlockchainUnitEnv, runBlockUnit)

# ------------------------------------------------------------------------------
# Engine tests
# ------------------------------------------------------------------------------

type
  ResponseError = object
    code: int
    message: string
    data: string

  Response[T] = object
    error: Opt[ResponseError]
    result: T

proc responseError(response: Response): Opt[string] =
  ## A JSON-RPC error as `<code>: <message>`, plus `: <data>` when it has data.
  if response.error.isNone:
    return Opt.none(string)

  template e: auto = response.error.value
  var text = $e.code & ": " & e.message
  if e.data.len > 0:
    text.add ": " & e.data
  Opt.some(text)

proc expectedCode(payload: PayloadItem): Opt[int] =
  template node: auto = payload.errorCode
  if node.isNone or node.get().len == 0:
    return Opt.none(int)
  try:
    var code: int
    if parseInt(node.value, code) == node.value.len and code != 0:
      return Opt.some(code)
    Opt.none(int)
  except ValueError:
    Opt.none(int)

proc forkchoiceUpdated(env: Env,
                       version: Version,
                       state: ForkchoiceStateV1): Response[ForkchoiceUpdatedResponse] =
  type ResultT = typeof(result)
  try:
    let res = waitFor noCancel env.engine.forkchoiceUpdated(
                Version(version), state, Opt.none(PayloadAttributes))
    ResultT(result: res)
  except RpcResponseError as exc:
    ResultT(error: Opt.some(ResponseError(
      code: exc.code,
      message: exc.msg,
      data: distinctBase exc.data,
    )))

proc forkchoice(env: Env, version: uint64, head: Hash32): string =
  ## Empty when the update is answered VALID.
  let state = ForkchoiceStateV1(
    headBlockHash: head,
    safeBlockHash: zeroHash32,
    finalizedBlockHash: zeroHash32,
  )

  if version == 0 or version > 4:
    return "forkchoiceUpdated unsupported version " & $version

  let
    res = env.forkchoiceUpdated(Version(version), state)
    error = responseError(res)

  if error.isSome:
    return "forkchoiceUpdated error " & error.get

  let
    status = res.result.payloadStatus.status
  if status != PayloadExecutionStatus.valid:
    return "forkchoiceUpdated status " & $status

  ""

proc newPayload(env: Env, version: uint64, param: PayloadParam): Response[PayloadStatus] =
  type ResultT = typeof(result)

  if version == 0 or version > 5:
    return ResultT(error: Opt.some(ResponseError(
      code: METHOD_NOT_FOUND,
      message: "newPayload unsupported version " & $version,
    )))

  try:
    let
      res = waitFor noCancel env.engine.newPayload(
        Version(version), param.payload, param.versionedHashes,
        param.parentBeaconBlockRoot, param.executionRequests)
    ResultT(result: res)
  except RpcResponseError as exc:
    ResultT(error: Opt.some(ResponseError(
      code: exc.code,
      message: exc.msg,
      data: distinctBase exc.data,
    )))

proc reportPayload(env: Env, opts: Options, payload: ExecutionPayload) =
  if not opts.balReport:
    return
  template list: auto = payload.blockAccessList
  env.reportExecution(
    opts,
    distinctBase payload.blockNumber,
    payload.blockHash,
    EthTime(payload.timestamp),
    list.isSome and list.get.len > 2,
  )

proc runEngineTest(
    env: Env, opts: Options, unit: EngineUnitEnv, genesisHash: Hash32,
    rejections: var seq[JsonNode],
): string =
  template payloads: auto = unit.engineNewPayloads

  if payloads.len == 0:
    return "fixture has no engineNewPayloads"

  let fcuVersion0 = distinctBase payloads[0].forkchoiceUpdatedVersion
  let first = env.forkchoice(fcuVersion0, genesisHash)
  if first.len > 0:
    return "initial " & first

  var failure = ""
  template fail(msg: string) =
    if failure.len == 0:
      failure = msg

  for i, payload in payloads:
    let
      version = distinctBase payload.newPayloadVersion
      fcuVersion = distinctBase payload.forkchoiceUpdatedVersion
      blockHash = payload.params.payload.blockHash
      wantCode = payload.expectedCode()
      validationError = payload.validationError
      expectValid =
        wantCode.isNone and (validationError.isNone or validationError.get().len == 0)
      response = env.newPayload(version, payload.params)
      error = responseError(response)

    if error.isSome:
      rejections.add rejection(i, Opt.none(Hash32), error.get)
      let got = response.error.value.code
      if wantCode.isNone:
        fail("payload " & $i & " unexpected JSON-RPC error " & error.get)
      elif wantCode.get != got:
        fail("payload " & $i & " JSON-RPC error code " & $got & ", expected " &
          $wantCode.get)
      continue

    let status = response.result.status
    if status in [PayloadExecutionStatus.valid, PayloadExecutionStatus.invalid]:
      env.reportPayload(opts, payload.params.payload)
    if status == PayloadExecutionStatus.invalid:
      rejections.add rejection(
        i, Opt.some(blockHash), response.result.validationError.get())
    if wantCode.isSome:
      fail("payload " & $i & " expected JSON-RPC error " & $wantCode.get &
        ", got status " & $status)
      continue

    let want = if expectValid: PayloadExecutionStatus.valid else: PayloadExecutionStatus.invalid
    if status != want:
      fail("payload " & $i & " status " & $status & ", expected " & $want &
        (if status == PayloadExecutionStatus.invalid: ": " & response.result.validationError.get()
         else: ""))
      continue
    if expectValid:
      let res = env.forkchoice(fcuVersion, blockHash)
      if res.len > 0:
        fail("payload " & $i & " " & res)

  if failure.len > 0:
    return failure
  if env.chain.latestHash != unit.lastblockhash:
    return "head " & $env.chain.latestHash & " is not lastblockhash " &
      $unit.lastblockhash
  ""

proc runEngineUnit(
    unit: EngineUnitEnv, opts: Options, taskpool: Taskpool,
    rejections: var seq[JsonNode],
): string =
  let genesis = unit.genesisHeader().valueOr:
    return error
  let env = prepareEnv(unit, genesis, opts, taskpool).valueOr:
    return error
  result =
    try:
      env.runEngineTest(opts, unit, genesis.computeBlockHash, rejections)
    except CatchableError as exc:
      "malformed fixture: " & exc.msg
  env.close()

proc runEngineFile(path: string, opts: Options, taskpool: Taskpool): string =
  runFile(path, EngineUnitEnv, runEngineUnit)

# ------------------------------------------------------------------------------
# Paths, workers and output
# ------------------------------------------------------------------------------

proc collectFiles(paths: seq[string], errors: var seq[string]): seq[string] =
  ## Every file named and every `.json` file under the directories named,
  ## sorted and each once; a path that cannot be found or read is an error.
  proc readable(file: string): bool =
    try:
      var f = open(longPath(file), fmRead)
      f.close()
      true
    except IOError:
      false

  for path in paths:
    if fileExists(path):
      result.add path
    elif dirExists(path):
      # walkDirRec checks only the top directory, so it would skip an
      # unreadable subdirectory and its fixtures without an error.
      var dirs = @[path]
      while dirs.len > 0:
        let dir = dirs.pop()
        try:
          for kind, entry in walkDir(dir, checkDir = true):
            case kind
            of pcDir, pcLinkToDir:
              dirs.add entry
            of pcFile, pcLinkToFile:
              if entry.endsWith(".json"):
                result.add entry
        except OSError as exc:
          errors.add "cannot read directory " & dir & ": " & exc.msg
    else:
      errors.add "no such fixture file or directory: " & path

  for file in result:
    if not readable(file):
      errors.add "cannot read " & file

  var seen: Table[string, bool]
  var unique: seq[string]
  for file in result:
    let key = try: expandFilename(file) except OSError: file
    if key notin seen:
      seen[key] = true
      unique.add file
  unique.sort()
  unique

proc worker(opts: Options) {.thread.} =
  {.gcsafe.}:
    var taskpool = try:
        Taskpool.new(numThreads = opts.threads)
      except CatchableError as exc:
        results.send("Etaskpool: " & exc.msg)
        return

    while true:
      let (ok, file) = work.tryRecv()
      if not ok:
        break
      let output =
        try:
          case opts.mode
          of BlockTest: runBlockFile(file, opts, taskpool)
          of EngineTest: runEngineFile(file, opts, taskpool)
        except CatchableError as exc:
          "E" & file & ": " & exc.msg
      results.send(output)
    taskpool.shutdown()

proc parseOptions(): tuple[opts: Options, paths: seq[string]] {.raises: [IOError].} =
  if paramCount() == 0:
    stderr.writeLine usage
    quit(2)
  if paramStr(1) == "--version":
    echo versionLine()
    quit(0)

  var opts = Options(
    workers: 1, threads: max(min(countProcessors(), 16), 2))
  case paramStr(1)
  of "blocktest": opts.mode = BlockTest
  of "enginetest": opts.mode = EngineTest
  of "--help", "-h":
    echo usage
    quit(0)
  else:
    stderr.writeLine "unknown command: " & paramStr(1) & "\n" & usage
    quit(2)

  var
    paths: seq[string]
    i = 2
  proc count(i: int, flag: string, least = 1): int {.raises: [IOError].} =
    if i > paramCount():
      stderr.writeLine flag & " needs a number"
      quit(2)
    try:
      result = parseInt(paramStr(i))
    except ValueError:
      stderr.writeLine flag & " needs a number, got " & paramStr(i)
      quit(2)
    if result < least:
      stderr.writeLine flag & " must be at least " & $least
      quit(2)

  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--workers":
      inc i
      opts.workers = count(i, arg)
    of "--threads":
      inc i
      # The parallel executor and prefetch need a taskpool of two or more.
      opts.threads = count(i, arg, least = 2)
    of "--bal-sequential": opts.balSequential = true
    of "--bal-report": opts.balReport = true
    of "--bal-withhold":
      if opts.mode != BlockTest:
        stderr.writeLine "--bal-withhold applies to blocktest only"
        quit(2)
      opts.balWithhold = true
    of "--version":
      echo versionLine()
      quit(0)
    else:
      if arg.startsWith("--"):
        stderr.writeLine "unknown flag: " & arg & "\n" & usage
        quit(2)
      paths.add arg
    inc i

  if paths.len == 0:
    stderr.writeLine "no fixture paths given\n" & usage
    quit(2)
  (opts, paths)

proc main() {.raises: [IOError, ResourceExhaustedError, KeyError].} =
  let (opts, paths) = parseOptions()

  var errors: seq[string]
  let files = collectFiles(paths, errors)
  if errors.len > 0:
    for e in errors:
      stderr.writeLine "error: " & e
    quit(2)

  work.open()
  results.open()
  for file in files:
    work.send(file)

  var threads = newSeq[Thread[Options]](min(opts.workers, max(files.len, 1)))
  for t in threads.mitems:
    createThread(t, worker, opts)
  joinThreads(threads)

  var
    all: seq[JsonNode]
    fileFailed = false
  while true:
    let (ok, msg) = results.tryRecv()
    if not ok:
      break
    if msg.startsWith("E"):
      stderr.writeLine "error: cannot run " & msg[1 .. ^1]
      fileFailed = true
    else:
      try:
        for r in parseJson(msg[1 .. ^1]).getElems():
          all.add r
      except CatchableError as exc:
        stderr.writeLine "error: unreadable results: " & exc.msg
        fileFailed = true
  all.sort(proc(a, b: JsonNode): int =
    try:
      cmp(a["name"].getStr, b["name"].getStr)
    except KeyError as exc:
      raiseAssert(exc.msg)
  )

  echo $(%all)
  let failed = all.countIt(not it["pass"].getBool)
  stderr.writeLine "Total: " & $all.len & " | Passed: " & $(all.len - failed) &
    " | Failed: " & $failed
  quit(if fileFailed: 2 elif failed > 0: 1 else: 0)

when isMainModule:
  main()
