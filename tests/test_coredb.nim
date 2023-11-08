# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Testing `CoreDB` wrapper implementation

import
  std/[os, strformat, strutils],
  chronicles,
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/core_db/persistent,
  ../../nimbus/core/chain,
  ./replay/pp,
  ./test_coredb/[coredb_test_xx, test_chainsync]

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

proc setErrorLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc openLegacyDB(
    persistent: bool;
    path: string;
    network: NetworkId;
      ): CommonRef =
  let coreDB = if not persistent: newCoreDbRef LegacyDbMemory
               else: newCoreDbRef(LegacyDbPersistent, path)
  result = CommonRef.new(
    db = coreDB,
    networkId = network,
    params = network.networkParams)
  result.initializeEmptyDb

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc chainSyncRunner(
    noisy = true;
    capture = bChainCapture;
    persistent = true;
      ) =
  ## Test legacy backend database
  let
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value
    baseDir = getTmpDir() / capture.name & "-legacy"
    dbDir = if persistent: baseDir / "tmp" else: ""
    sayPersistent = if persistent: "persistent DB" else: "mem DB only"
    numBlocks = capture.numBlocks
    numBlocksInfo = if numBlocks == high(int): "" else: $numBlocks & " "

  defer:
    if persistent: baseDir.flushDbDir

  suite "CoreDB and LedgerRef API"&
        &", capture={fileInfo}, {sayPersistent}":

    test &"Ledger API, {numBlocksInfo} blocks":
      let
        com = openLegacyDB(persistent, dbDir, capture.network)
      defer:
        com.db.finish(flush = true)
        if persistent: dbDir.flushDbDir

      check noisy.testChainSync(filePath, com, numBlocks)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc coreDbMain*(noisy = defined(debug)) =
  noisy.chainSyncRunner()

when isMainModule:
  const
    noisy = defined(debug) or true
    persDb = true and false

  setErrorLevel()

  # This one uses the readily available dump: `bulkTest0` and some huge replay
  # dumps `bulkTest2`, `bulkTest3`, .. from the `nimbus-eth1-blobs` package.
  # For specs see `tests/test_coredb/bulk_test_xx.nim`.
  var testList = @[bulkTest0] # This test is superseded by `bulkTest1` and `2`
  testList = @[failSample0]
  when true and false:
    testList = @[bulkTest2, bulkTest3]

  for n,capture in testList:
    noisy.chainSyncRunner(capture=capture, persistent=persDb)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
