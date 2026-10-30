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

import
  std/[algorithm, cpuinfo, json, os, parseutils, sequtils, strutils, tables],
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
  ../../execution_chain/common/common,
  ../../tests/eest/eest_parser,
  ../../tests/eest/bal_parser

import ../common/helpers as chp except HardFork
from ../evmstate/helpers import setupLedger

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

  RawEngineUnitEnv = object of UnitEnv
    engineNewPayloads: JsonNode

  Env = ref object
    chain: ForkedChainRef
    engine: BeaconEngineRef
    server: RpcServer
    kept: Table[Hash32, string]
      ## Blocks whose list the runner kept back, with the report's reason.

RawEngineUnitEnv.useDefaultReaderIn EthJson

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

  let
    memDB = newCoreDbRef(DefaultDbMemory, enableCaches = true)
    ledger = LedgerRef.init(memDB.baseTxFrame())
  setupLedger(unit.pre, ledger)
  ledger.persist()
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

  if opts.balReport:
    com.balExecutionCB = proc(
        header: Header, parallel: bool, reason: string
    ) {.gcsafe, raises: [].} =
      let hash = header.computeBlockHash
      let line = %*{
        "event": "balExecution",
        "block": header.number,
        "hash": hash.data.to0xHex(),
        "path": (if parallel: "parallel" else: "sequential"),
        "reason": env.kept.getOrDefault(hash, reason),
      }
      try:
        stderr.write($line & "\n")
        stderr.flushFile()
      except IOError:
        discard

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
    env: Env, blk: JsonNode, header: Header, opts: Options
): Opt[BlockAccessListRef] =
  ## The fixture's list for this block, attached when its hash matches the
  ## header's and dropped otherwise, as the interface asks.
  let node =
    if "blockAccessList" in blk:
      blk["blockAccessList"]
    elif "rlp_decoded" in blk and "blockAccessList" in blk["rlp_decoded"]:
      blk["rlp_decoded"]["blockAccessList"]
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

  for i, x in unit.blocks.getElems():
    let expectInvalid = "expectException" in x
    let blk =
      try:
        rlp.decode(hexToSeqByte(x["rlp"].getStr), Block)
      except CatchableError as exc:
        rejections.add rejection(i, Opt.none(Hash32), exc.msg)
        if not expectInvalid:
          fail("block " & $i & " failed to decode: " & exc.msg)
        continue

    let
      hash = blk.header.computeBlockHash
      bal = env.deliveredList(x, blk.header, opts)
      res = waitFor env.chain.importBlock(blk, bal)
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

template runFile(path: string, T: type, runUnit: untyped): string =
  ## A file that is not JSON cannot be run; a fixture in it that Nimbus cannot
  ## read, such as one for a fork it does not know, fails on its own.
  let fixtures =
    try:
      parseFile(path)
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

proc call(env: Env, meth: string, params: JsonNode): JsonNode =
  ## One JSON-RPC request through Nimbus's own method dispatch.
  let request = $(%*{"jsonrpc": "2.0", "id": 1, "method": meth, "params": params})
  let response = waitFor env.server.route(request)
  try:
    parseJson(response)
  except CatchableError as exc:
    %*{"error": {"code": 0, "message": "unreadable response: " & exc.msg}}

proc rpcError(response: JsonNode): Opt[string] =
  ## A JSON-RPC error as `<code>: <message>`, plus `: <data>` when it has data.
  if "error" notin response:
    return Opt.none(string)
  let e = response["error"]
  var text = $e{"code"}.getInt & ": " & e{"message"}.getStr
  if e.hasKey("data") and e["data"].kind != JNull:
    text.add ": " &
      (if e["data"].kind == JString: e["data"].getStr else: $e["data"])
  Opt.some(text)

proc expectedCode(payload: JsonNode): Opt[int] =
  let node = payload{"errorCode"}
  if node.isNil or node.kind == JNull:
    return Opt.none(int)
  if node.kind == JInt:
    return Opt.some(node.getInt)
  var code: int
  if parseInt(node.getStr, code) == node.getStr.len and code != 0:
    return Opt.some(code)
  Opt.none(int)

proc forkchoice(env: Env, version: int, head: string): string =
  ## Empty when the update is answered VALID.
  let state = %*{
    "headBlockHash": head,
    "safeBlockHash": zeroHash32.data.to0xHex(),
    "finalizedBlockHash": zeroHash32.data.to0xHex(),
  }
  let response = env.call("engine_forkchoiceUpdatedV" & $version, %*[state, nil])
  let error = rpcError(response)
  if error.isSome:
    return "forkchoiceUpdated error " & error.get
  let status = response{"result"}{"payloadStatus"}{"status"}.getStr
  if status != "VALID":
    return "forkchoiceUpdated status " & status
  ""

proc runEngineTest(
    env: Env, unit: RawEngineUnitEnv, genesis: Hash32, rejections: var seq[JsonNode]
): string =
  let payloads = unit.engineNewPayloads.getElems()
  if payloads.len == 0:
    return "fixture has no engineNewPayloads"

  let fcuVersion0 = payloads[0]{"forkchoiceUpdatedVersion"}.getStr("1").parseInt
  let first = env.forkchoice(fcuVersion0, genesis.data.to0xHex())
  if first.len > 0:
    return "initial " & first

  var failure = ""
  template fail(msg: string) =
    if failure.len == 0:
      failure = msg

  for i, payload in payloads:
    let
      version = payload["newPayloadVersion"].getStr.parseInt
      fcuVersion = payload["forkchoiceUpdatedVersion"].getStr.parseInt
      blockHash = payload["params"][0]{"blockHash"}.getStr
      wantCode = payload.expectedCode()
      validationError = payload{"validationError"}
      expectValid =
        wantCode.isNone and (validationError.isNil or validationError.kind == JNull)
      response = env.call("engine_newPayloadV" & $version, payload["params"])

    let error = rpcError(response)
    if error.isSome:
      rejections.add rejection(i, Opt.none(Hash32), error.get)
      let got = response["error"]{"code"}.getInt
      if wantCode.isNone:
        fail("payload " & $i & " unexpected JSON-RPC error " & error.get)
      elif wantCode.get != got:
        fail("payload " & $i & " JSON-RPC error code " & $got & ", expected " &
          $wantCode.get)
      continue

    let status = response{"result"}{"status"}.getStr
    if status == "INVALID":
      let hash =
        try:
          Opt.some(Hash32.fromHex(blockHash))
        except ValueError:
          Opt.none(Hash32)
      rejections.add rejection(
        i, hash, response["result"]{"validationError"}.getStr)
    if wantCode.isSome:
      fail("payload " & $i & " expected JSON-RPC error " & $wantCode.get &
        ", got status " & status)
      continue
    let want = if expectValid: "VALID" else: "INVALID"
    if status != want:
      fail("payload " & $i & " status " & status & ", expected " & want &
        (if status == "INVALID": ": " & response["result"]{"validationError"}.getStr
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
    unit: RawEngineUnitEnv, opts: Options, taskpool: Taskpool,
    rejections: var seq[JsonNode],
): string =
  let genesis = unit.genesisHeader().valueOr:
    return error
  let env = prepareEnv(unit, genesis, opts, taskpool).valueOr:
    return error
  result =
    try:
      env.runEngineTest(unit, genesis.computeBlockHash, rejections)
    except CatchableError as exc:
      "malformed fixture: " & exc.msg
  env.close()

proc runEngineFile(path: string, opts: Options, taskpool: Taskpool): string =
  runFile(path, RawEngineUnitEnv, runEngineUnit)

# ------------------------------------------------------------------------------
# Paths, workers and output
# ------------------------------------------------------------------------------

proc collectFiles(paths: seq[string], errors: var seq[string]): seq[string] =
  ## Every file named and every `.json` file under the directories named,
  ## sorted and each once; a path that cannot be found or read is an error.
  proc readable(file: string): bool =
    try:
      var f = open(file, fmRead)
      f.close()
      true
    except IOError:
      false

  for path in paths:
    if fileExists(path):
      result.add path
    elif dirExists(path):
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
    var taskpool = Taskpool.new(numThreads = opts.threads)
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

proc parseOptions(): tuple[opts: Options, paths: seq[string]] =
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
  proc count(i: int, flag: string, least = 1): int =
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

proc main() =
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
  all.sort(proc(a, b: JsonNode): int = cmp(a["name"].getStr, b["name"].getStr))

  echo $(%all)
  let failed = all.countIt(not it["pass"].getBool)
  stderr.writeLine "Total: " & $all.len & " | Passed: " & $(all.len - failed) &
    " | Failed: " & $failed
  quit(if fileFailed: 2 elif failed > 0: 1 else: 0)

when isMainModule:
  main()
