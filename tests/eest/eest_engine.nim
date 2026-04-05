# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
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
  ../../execution_chain/core/tx_pool,
  ../../execution_chain/beacon/beacon_engine,
  ../../execution_chain/common/common,
  ../../hive_integration/engine_client,
  ./eest_helpers

proc sendNewPayload(env: TestEnv, version: uint64, param: PayloadParam): Result[PayloadStatusV1, string] =
  if not env.client.isSome:
    return err("Client is not initialized")

  if version == 1:
    env.client.get().newPayloadV1(
      param.payload)
  elif version == 2:
    env.client.get().newPayloadV2(
      param.payload)
  elif version == 3:
    env.client.get().newPayloadV3(
      param.payload,
      param.versionedHashes,
      param.parentBeaconBlockRoot)
  elif version == 4:
    env.client.get().newPayloadV4(
      param.payload,
      param.versionedHashes,
      param.parentBeaconBlockRoot,
      param.executionRequests)
  elif version == 5:
    env.client.get().newPayloadV5(
      param.payload,
      param.versionedHashes,
      param.parentBeaconBlockRoot,
      param.executionRequests)
  else:
    err("Unsupported NewPayload version: " & $version)

proc sendFCU(env: TestEnv, version: uint64, param: PayloadParam): Result[ForkchoiceUpdatedResponse, string] =
  if not env.client.isSome:
    return err("Client is not initialized")

  let update = ForkchoiceStateV1(
    headblockHash:      param.payload.blockHash,
    finalizedblockHash: param.payload.blockHash
  )

  if version == 1:
    env.client.get().forkchoiceUpdatedV1(update)
  elif version == 2:
    env.client.get().forkchoiceUpdatedV2(update)
  elif version == 3:
    env.client.get().forkchoiceUpdatedV3(update)
  elif version == 4:
    env.client.get().forkchoiceUpdatedV4(update)
  else:
    err("Unsupported FCU version: " & $version)

proc runTest(env: TestEnv, unit: EngineUnitEnv): Result[void, string] =
  if not env.client.isSome:
    return err("Client is not initialized")

  for enp in unit.engineNewPayloads:

    var status = env.sendNewPayload(enp.newPayloadVersion.uint64, enp.params).valueOr:
      if enp.validationError.isSome():
        continue
      else:
        return err(error)

    discard status
    when false:
      # Skip validation error check, use `unit.lastblockhash` to
      # determine if the test is pass.
      if status.validationError.isSome:
        return err(status.validationError.value)

    let y = env.sendFCU(enp.forkchoiceUpdatedVersion.uint64, enp.params).valueOr:
      return err(error)

    discard y
    when false:
      # ditto
      status = y.payloadStatus
      if status.validationError.isSome:
        return err(status.validationError.value)

  let header = env.chain.latestHeader()

  if unit.lastblockhash != header.computeRlpHash:
    return err("last block hash mismatch")

  ok()

proc processFile*(fileName: string, statelessEnabled = false): bool =
  let
    fixture = parseFixture(fileName, EngineFixture)

  var testPass = true
  for unit in fixture.units:
    let header = unit.unit.genesisBlockHeader.to(Header)
    doAssert(unit.unit.genesisBlockHeader.hash == header.computeRlpHash)
    let env = prepareEnv(unit.unit, header, rpcEnabled = true, statelessEnabled)
    env.runTest(unit.unit).isOkOr:
      echo "\nTestName: ", unit.name, " RunTest error: ", error, "\n"
      testPass = false
    env.close()

  return testPass

{.pop.}  # undo {.push raises: [], gcsafe.} for isMainModule block

when isMainModule:
  import
    std/[json, os, parseopt, strutils]

  type
    TestResult = object
      name: string
      pass: bool
      error: string

  proc collectJsonFiles(path: string): seq[string] {.raises: [OSError].} =
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
    echo "  " & testFile & " --json /path/to/blockchain_tests_engine/"
    echo "  " & testFile & " --run=eip7702 /path/to/blockchain_tests_engine/"

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
