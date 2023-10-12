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

## Snap sync components tester and TDD environment

import
  std/[distros, os, strformat, strutils, tables],
  chronicles,
  eth/[common, p2p],
  rocksdb,
  unittest2,
  ../nimbus/db/core_db/persistent,
  ../nimbus/core/chain,
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/db/hexary_desc,
  ./replay/pp,
  ./test_rocksdb_timing/[bulk_test_xx, test_db_timing]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"/"replay", "tests"/"test_sync_snap",
             "nimbus-eth1-blobs"/"replay"]

  # Reference file for finding the database directory
  sampleDirRefFile = "sample0.txt.gz"

  # Standard test samples
  bChainCapture = bulkTest0

  # Number of database slots (needed for timing tests)
  nTestDbInstances = 9

type
  TestDbs = object
    ## Provide enough spare empty databases
    persistent: bool
    dbDir: string
    baseDir: string # for cleanup
    subDir: string  # for cleanup
    cdb: array[nTestDbInstances,CoreDbRef]

when defined(linux):
  # The `detectOs(Ubuntu)` directive is not Windows compatible, causes an
  # error when running the system command `lsb_release -d` in the background.
  let isUbuntu32bit = detectOs(Ubuntu) and int.sizeof == 4
else:
  const isUbuntu32bit = false

let
  # There was a problem with the Github/CI which results in spurious crashes
  # when leaving the `runner()` if the persistent ChainDBRef initialisation
  # was present, see `test_custom_network` for more details.
  disablePersistentDB = isUbuntu32bit

var
  xTmpDir: string
  xDbs: TestDbs                   # for repeated storage/overwrite tests
  xTab32: Table[ByteArray32,Blob] # extracted data
  xTab33: Table[ByteArray33,Blob]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string;
                  baseDir, repoDir: openArray[string]): Result[string,void] =
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return ok(path)
  echo "*** File not found \"", file, "\"."
  err()

proc getTmpDir(sampleDir = sampleDirRefFile): string =
  sampleDir.findFilePath(baseDir,repoDir).value.splitFile.dir

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

proc flushDbDir(s: string; subDir = "") =
  if s != "":
    let baseDir = s / "tmp"
    for n in 0 ..< nTestDbInstances:
      let instDir = if subDir == "": baseDir / $n else: baseDir / subDir / $n
      if (instDir / "nimbus" / "data").dirExists:
        # Typically under Windows: there might be stale file locks.
        try: instDir.removeDir except CatchableError: discard
    try: (baseDir / subDir).removeDir except CatchableError: discard
    block dontClearUnlessEmpty:
      for w in baseDir.walkDir:
        break dontClearUnlessEmpty
      try: baseDir.removeDir except CatchableError: discard


proc flushDbs(db: TestDbs) =
  if db.persistent:
    for n in 0 ..< nTestDbInstances:
      if db.cdb[n].isNil or db.cdb[n].dbType != LegacyDbPersistent:
         break
      db.cdb[n].backend.toRocksStoreRef.store.db.rocksdb_close
    db.baseDir.flushDbDir(db.subDir)

proc testDbs(
    workDir: string;
    subDir: string;
    instances: int;
    persistent: bool;
      ): TestDbs =
  if disablePersistentDB or workDir == "" or not persistent:
    result.persistent = false
    result.dbDir = "*notused*"
  else:
    result.persistent = true
    result.baseDir = workDir
    result.subDir = subDir
    if subDir != "":
      result.dbDir = workDir / "tmp" / subDir
    else:
      result.dbDir = workDir / "tmp"
  if result.persistent:
    workDir.flushDbDir(subDir)
    for n in 0 ..< min(result.cdb.len, instances):
      result.cdb[n] = newCoreDbRef(LegacyDbPersistent, result.dbDir / $n)

# ------------------------------------------------------------------------------
# Test Runners: database timing tests
# ------------------------------------------------------------------------------

proc importRunner(noisy = true;  persistent = true; capture = bChainCapture) =
  let
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value
    tmpDir = getTmpDir()
    db = tmpDir.testDbs(capture.name & "-import", instances=1, persistent)
    numBlocks = capture.numBlocks
    numBlocksInfo = if numBlocks == high(int): "" else: $numBlocks & " "
    loadNoise = noisy

  defer:
    db.flushDbs

  suite &"RocksDB: using {fileInfo} capture for testing db timings":
    var ddb: CommonRef         # perstent DB on disk

    test &"Create persistent ChainDBRef on {tmpDir}":
      ddb = CommonRef.new(
        db = if db.persistent: db.cdb[0] else: newCoreDbRef(LegacyDbMemory),
        networkId = capture.network,
        pruneTrie = true,
        params = capture.network.networkParams)
      ddb.initializeEmptyDb

    test &"Storing {numBlocksInfo}persistent blocks from dump":
      noisy.test_dbTimingUndumpBlocks(filePath, ddb, numBlocks, loadNoise)

    test "Extract key-value records into memory tables via rocksdb iterator":
      if db.cdb[0].backend.toRocksStoreRef.isNil:
        skip() # not persistent => db.cdb[0] is nil
      else:
        noisy.test_dbTimingRockySetup(xTab32, xTab33, db.cdb[0])


proc dbTimingRunner(noisy = true;  persistent = true; cleanUp = true) =
  let
    fullNoise = false
  var
    emptyDb = "empty"

  # Allows to repeat storing on existing data
  if not xDbs.cdb[0].isNil:
    emptyDb = "pre-loaded"
  else:
    xTmpDir = getTmpDir()
    xDbs = xTmpDir.testDbs(
      "timing-runner", instances=nTestDbInstances, persistent)

  defer:
    if cleanUp:
      xDbs.flushDbs
      xDbs.reset

  suite &"RocksDB: storage tests on {emptyDb} databases":
    #
    # `xDbs` instance slots layout:
    #
    # * cdb[0] -- direct db, key length 32, no transaction
    # * cdb[1] -- direct db, key length 32 as 33, no transaction
    #
    # * cdb[2] -- direct db, key length 32, transaction based
    # * cdb[3] -- direct db, key length 32 as 33, transaction based
    #
    # * cdb[4] -- direct db, key length 33, no transaction
    # * cdb[5] -- direct db, key length 33, transaction based
    #
    # * cdb[6] -- rocksdb, key length 32
    # * cdb[7] -- rocksdb, key length 32 as 33
    # * cdb[8] -- rocksdb, key length 33
    #
    doAssert 9 <= nTestDbInstances
    doAssert not xDbs.cdb[8].isNil

    let
      storeDir32 = &"Directly store {xTab32.len} records"
      storeDir33 = &"Directly store {xTab33.len} records"
      storeTx32 = &"Transactionally store directly {xTab32.len} records"
      storeTx33 = &"Transactionally store directly {xTab33.len} records"
      intoTrieDb = &"into {emptyDb} trie db"

      storeRks32 = &"Store {xTab32.len} records"
      storeRks33 = &"Store {xTab33.len} records"
      intoRksDb = &"into {emptyDb} rocksdb table"

    if xTab32.len == 0 or xTab33.len == 0:
      test &"Both tables with 32 byte keys(size={xTab32.len}), " &
          &"33 byte keys(size={xTab32.len}) must be non-empty":
        skip()
    else:
      test &"{storeDir32} (key length 32) {intoTrieDb}":
        noisy.test_dbTimingStoreDirect32(xTab32, xDbs.cdb[0])

      test &"{storeDir32} (key length 33) {intoTrieDb}":
        noisy.test_dbTimingStoreDirectly32as33(xTab32, xDbs.cdb[1])

      test &"{storeTx32} (key length 32) {intoTrieDb}":
        noisy.test_dbTimingStoreTx32(xTab32, xDbs.cdb[2])

      test &"{storeTx32} (key length 33) {intoTrieDb}":
        noisy.test_dbTimingStoreTx32as33(xTab32, xDbs.cdb[3])

      test &"{storeDir33} (key length 33) {intoTrieDb}":
        noisy.test_dbTimingDirect33(xTab33, xDbs.cdb[4])

      test &"{storeTx33} (key length 33) {intoTrieDb}":
        noisy.test_dbTimingTx33(xTab33, xDbs.cdb[5])

      if xDbs.cdb[0].backend.toRocksStoreRef.isNil:
        test "The rocksdb interface must be available": skip()
      else:
        test &"{storeRks32} (key length 32) {intoRksDb}":
          noisy.test_dbTimingRocky32(xTab32, xDbs.cdb[6], fullNoise)

        test &"{storeRks32} (key length 33) {intoRksDb}":
          noisy.test_dbTimingRocky32as33(xTab32, xDbs.cdb[7], fullNoise)

        test &"{storeRks33} (key length 33) {intoRksDb}":
          noisy.test_dbTimingRocky33(xTab33, xDbs.cdb[8], fullNoise)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc rocksDbTimingMain*(noisy = defined(debug)) =
  noisy.importRunner() # small sample, just verify functionality
  noisy.dbTimingRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  #setTraceLevel()
  setErrorLevel()

  # This one uses the readily available dump: `bulkTest0` and some huge replay
  # dumps `bulkTest2`, `bulkTest3`, .. from the `nimbus-eth1-blobs` package.
  # For specs see `tests/test_rocksdb_timing/bulk_test_xx.nim`.
  var testList = @[bulkTest0]
  when true and false:
    testList &= @[bulkTest1, bulkTest2, bulkTest3]

  for test in testList:
    noisy.showElapsed("importRunner()"):
      noisy.importRunner(capture = test)

    noisy.showElapsed("dbTimingRunner()"):
      true.dbTimingRunner(cleanUp = false)
      true.dbTimingRunner()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
