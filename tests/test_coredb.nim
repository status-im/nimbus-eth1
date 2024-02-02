# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Testing `CoreDB` wrapper implementation

import
  std/[os, strformat, strutils, times],
  chronicles,
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/[core_db/persistent, ledger],
  ../../nimbus/core/chain,
  ./replay/pp,
  ./test_coredb/[coredb_test_xx, test_chainsync, test_helpers]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests", "nimbus-eth1-blobs"]
  subDir = ["replay", "test_coredb"]

  # Reference file for finding some database directory base
  sampleDirRefFile = "coredb_test_xx.nim"

  # Standard test sample
  bChainCapture = bulkTest0

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(
    file: string;
    baseDir: openArray[string] = baseDir;
    repoDir: openArray[string] = repoDir;
    subDir: openArray[string] = subDir;
      ): Result[string,void] =
  for dir in baseDir:
    if dir.dirExists:
      for repo in repoDir:
        if (dir / repo).dirExists:
          for sub in subDir:
            if (dir / repo / sub).dirExists:
              let path = dir / repo / sub / file
              if path.fileExists:
                return ok(path)
  echo "*** File not found \"", file, "\"."
  err()

proc getTmpDir(sampleDir = sampleDirRefFile): string =
  sampleDir.findFilePath.value.splitFile.dir

proc flushDbDir(s: string) =
  if s != "":
    let dataDir = s / "nimbus"
    if (dataDir / "data").dirExists:
      # Typically under Windows: there might be stale file locks.
      try: dataDir.removeDir except CatchableError: discard
    block dontClearUnlessEmpty:
      for w in s.walkDir:
        break dontClearUnlessEmpty
      try: s.removeDir except CatchableError: discard

# ----------------

proc setTraceLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setDebugLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.DEBUG)

proc setErrorLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc initRunnerDB(
    path: string;
    network: NetworkId;
    dbType: CoreDbType;
    ldgType: LedgerType;
      ): CommonRef =
  let coreDB =
    # Resolve for static `dbType`
    case dbType:
    of LegacyDbMemory: LegacyDbMemory.newCoreDbRef()
    of LegacyDbPersistent: LegacyDbPersistent.newCoreDbRef path
    of AristoDbMemory: AristoDbMemory.newCoreDbRef()
    of AristoDbRocks: AristoDbRocks.newCoreDbRef path
    of AristoDbVoid: AristoDbVoid.newCoreDbRef()
    else: raiseAssert "Oops"

  when false: # or true:
    setDebugLevel()
    coreDB.trackLegaApi = true
    coreDB.trackNewApi = true
    coreDB.localDbOnly = true

  result = CommonRef.new(
    db = coreDB,
    networkId = network,
    params = network.networkParams,
    ldgType = ldgType)

  result.initializeEmptyDb

  setErrorLevel()
  coreDB.trackLegaApi = false
  coreDB.trackNewApi = false
  coreDB.localDbOnly = false

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc chainSyncRunner(
    noisy = true;
    capture = bChainCapture;
    dbType = LegacyDbMemory;
    ldgType = LegacyAccountsCache;
    enaLogging = false;
    lastOneExtra = true;
      ) =
  ## Test backend database and ledger
  let
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value
    baseDir = getTmpDir() / capture.name & "-chain-sync"
    dbDir = baseDir / "tmp"
    numBlocks = capture.numBlocks
    numBlocksInfo = if numBlocks == high(int): "all" else: $numBlocks
    persistent = dbType in CoreDbPersistentTypes

  defer:
    if persistent: baseDir.flushDbDir

  suite &"CoreDB and LedgerRef API on {fileInfo}, {dbType}, {ldgType}":

    test &"Ledger API {ldgType}, {numBlocksInfo} blocks":
      let
        com = initRunnerDB(dbDir, capture.network, dbType, ldgType)
      defer:
        com.db.finish(flush = true)
        noisy.testChainSyncProfilingPrint numBlocks
        if persistent: dbDir.flushDbDir

      if noisy:
        com.db.trackNewApi = true
        com.db.trackNewApi = true
        com.db.trackLedgerApi = true
        com.db.localDbOnly = true

      check noisy.testChainSync(filePath, com, numBlocks,
        lastOneExtra=lastOneExtra, enaLogging=enaLogging)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc coreDbMain*(noisy = defined(debug)) =
  noisy.chainSyncRunner(ldgType=LedgerCache)

when isMainModule:
  const
    noisy = defined(debug) or true

  setErrorLevel()

  # This one uses the readily available dump: `bulkTest0` and some huge replay
  # dumps `bulkTest2`, `bulkTest3`, .. from the `nimbus-eth1-blobs` package.
  # For specs see `tests/test_coredb/bulk_test_xx.nim`.
  var testList = @[bulkTest0] # This test is superseded by `bulkTest1` and `2`
  testList = @[failSample0]
  when true and false:
    testList = @[bulkTest2, bulkTest3]

  var state: (Duration, int)
  for n,capture in testList:
    noisy.profileSection("@testList #" & $n, state):
      noisy.chainSyncRunner(
        capture=capture,
        dbType=AristoDbMemory,
        ldgType=LedgerCache,
        #enaLogging=true
      )

  noisy.say "***", "total elapsed: ", state[0].pp, " sections: ", state[1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
