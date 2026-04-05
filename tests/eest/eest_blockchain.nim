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
  ../../execution_chain/db/ledger,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/engine_client,
  ./eest_helpers,
  stew/byteutils,
  chronos

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
    echo "  --run=<pattern>    Substring filter on file paths"
    echo "  --json             Output results as JSON array"
    echo "  --workers=<N>      Number of workers (accepted, runs sequentially)"
    echo ""
    echo "Examples:"
    echo "  " & testFile & " vector.json"
    echo "  " & testFile & " --json /path/to/blockchain_tests/"
    echo "  " & testFile & " --run=eip7702 /path/to/blockchain_tests/"

  var
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

  discard workers  # sequential only; flag accepted for CLI compatibility

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

  var
    results: seq[TestResult]
    passCount = 0
    failCount = 0

  for f in files:
    let pass = processFile(f)
    let rel = if dirExists(inputPath):
                f.relativePath(inputPath)
              else:
                f.splitPath().tail
    var errMsg = ""
    if not pass:
      errMsg = "test failed"
      inc failCount
    else:
      inc passCount
    results.add(TestResult(name: rel, pass: pass, error: errMsg))
    if not jsonEnabled:
      if pass:
        echo "PASS: ", rel
      else:
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
