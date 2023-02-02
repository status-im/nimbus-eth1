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
  std/[distros, os, sets, sequtils, strformat, strutils, tables],
  chronicles,
  eth/[common, p2p],
  rocksdb,
  unittest2,
  ../nimbus/db/select_backend,
  ../nimbus/core/chain,
  ../nimbus/sync/types,
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_envelope, hexary_error, hexary_inspect, hexary_nearby,
    hexary_paths, rocky_bulk_load, snapdb_accounts, snapdb_desc],
  ./replay/[pp, undump_accounts, undump_storages],
  ./test_sync_snap/[
    bulk_test_xx, snap_test_xx,
    test_accounts, test_calc, test_helpers, test_node_range, test_inspect,
    test_pivot, test_storage, test_db_timing, test_types]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"/"replay", "tests"/"test_sync_snap",
             "nimbus-eth1-blobs"/"replay"]

  # Reference file for finding the database directory
  sampleDirRefFile = "sample0.txt.gz"

  # Standard test samples
  bChainCapture = bulkTest0
  accSample = snapTest0
  storSample = snapTest4

  # Number of database slots (needed for timing tests)
  nTestDbInstances = 9

type
  TestDbs = object
    ## Provide enough spare empty databases
    persistent: bool
    dbDir: string
    cdb: array[nTestDbInstances,ChainDb]

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

proc setTraceLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc to(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath(baseDir,repoDir).value
  var root: Hash256
  for w in file.undumpNextAccount:
    let n = w.seenAccounts - 1
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to(sample: AccountsSample; T: type seq[UndumpStorages]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath(baseDir,repoDir).value
  var root: Hash256
  for w in file.undumpNextStorages:
    let n = w.seenAccounts - 1 # storages selector based on accounts
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc flushDbDir(s: string; subDir = "") =
  if s != "":
    let baseDir = s / "tmp"
    for n in 0 ..< nTestDbInstances:
      let instDir = if subDir == "": baseDir / $n else: baseDir / subDir / $n
      if (instDir / "nimbus" / "data").dirExists:
        # Typically under Windows: there might be stale file locks.
        try: instDir.removeDir except: discard
    try: (baseDir / subDir).removeDir except: discard
    block dontClearUnlessEmpty:
      for w in baseDir.walkDir:
        break dontClearUnlessEmpty
      try: baseDir.removeDir except: discard

proc testDbs(workDir = ""; subDir = ""; instances = nTestDbInstances): TestDbs =
  if disablePersistentDB or workDir == "":
    result.persistent = false
    result.dbDir = "*notused*"
  else:
    result.persistent = true
    if subDir != "":
      result.dbDir = workDir / "tmp" / subDir
    else:
      result.dbDir = workDir / "tmp"
  if result.persistent:
    result.dbDir.flushDbDir
    for n in 0 ..< min(result.cdb.len, instances):
      result.cdb[n] = (result.dbDir / $n).newChainDB

proc snapDbRef(cdb: ChainDb; pers: bool): SnapDbRef =
  if pers: SnapDbRef.init(cdb) else: SnapDbRef.init(newMemoryDB())

proc snapDbAccountsRef(cdb:ChainDb; root:Hash256; pers:bool):SnapDbAccountsRef =
  SnapDbAccountsRef.init(cdb.snapDbRef(pers), root, Peer())

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc miscRunner(noisy = true) =

  suite "SyncSnap: Verify setup, constants, limits":

    test "RLP accounts list sizes":
      test_calcAccountsListSizes()

    test "RLP proofs list sizes":
      test_calcProofsListSizes()


proc accountsRunner(noisy = true;  persistent = true; sample = accSample) =
  let
    accLst = sample.to(seq[UndumpAccounts])
    root = accLst[0].root
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(sample.name, instances=2) else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    if db.persistent:
      if not db.cdb[0].rocksStoreRef.isNil:
        db.cdb[0].rocksStoreRef.store.db.rocksdb_close
        db.cdb[1].rocksStoreRef.store.db.rocksdb_close
      tmpDir.flushDbDir(sample.name)

  suite &"SyncSnap: {fileInfo} accounts and proofs for {info}":

    block:
      # New common descriptor for this sub-group of tests
      let
        desc = db.cdb[0].snapDbAccountsRef(root, db.persistent)
        hexaDb = desc.hexaDb
        getFn = desc.getAccountFn
        dbg = if noisy: hexaDb else: nil

      test &"Proofing {accLst.len} list items for state root ..{root.pp}":
        accLst.test_accountsImport(desc, db.persistent)

      # debugging, make sure that state root ~ "$0"
      desc.assignPrettyKeys()

      # Beware: dumping a large database is not recommended
      # true.say "***", "database dump\n    ", desc.dumpHexaDB()

      test &"Retrieve accounts & proofs for previous account ranges":
        if db.persistent:
          accLst.test_NodeRangeProof(getFn, dbg)
        else:
          accLst.test_NodeRangeProof(hexaDB, dbg)

      test &"Verify left boundary checks":
        if db.persistent:
          accLst.test_NodeRangeLeftBoundary(getFn, dbg)
        else:
          accLst.test_NodeRangeLeftBoundary(hexaDB, dbg)

    block:
      # List of keys to be shared by sub-group
      var accKeys: seq[NodeKey]

      # New common descriptor for this sub-group of tests
      let
        cdb = db.cdb[1]
        desc = cdb.snapDbAccountsRef(root, db.persistent)

      test &"Merging {accLst.len} accounts/proofs lists into single list":
        accLst.test_accountsMergeProofs(desc, accKeys) # set up `accKeys`

      test &"Revisiting {accKeys.len} stored items on ChainDBRef":
        accKeys.test_accountsRevisitStoredItems(desc, noisy)

      test &"Decompose path prefix envelopes on {info}":
        let hexaDb = desc.hexaDb
        if db.persistent:
          accKeys.test_NodeRangeDecompose(root, desc.getAccountFn, hexaDb)
        else:
          accKeys.test_NodeRangeDecompose(root, hexaDb, hexaDb)

      test &"Storing/retrieving {accKeys.len} stored items " &
          "on persistent pivot/checkpoint registry":
        if db.persistent:
          accKeys.test_pivotStoreRead(cdb)
        else:
          skip()


proc storagesRunner(
    noisy = true;
    persistent = true;
    sample = storSample;
    knownFailures: seq[(string,seq[(int,HexaryError)])] = @[]) =
  let
    accLst = sample.to(seq[UndumpAccounts])
    stoLst = sample.to(seq[UndumpStorages])
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(sample.name, instances=1) else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"
    idPfx = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    if db.persistent:
      if not db.cdb[0].rocksStoreRef.isNil:
        db.cdb[0].rocksStoreRef.store.db.rocksdb_close
      tmpDir.flushDbDir(sample.name)

  suite &"SyncSnap: {idPfx} accounts storage for {info}":
    let xdb = db.cdb[0].snapDbRef(db.persistent)

    test &"Merging {accLst.len} accounts for state root ..{accLst[0].root.pp}":
      accLst.test_storageAccountsImport(xdb, db.persistent)

    test &"Merging {stoLst.len} storages lists":
      stoLst.test_storageSlotsImport(xdb, db.persistent, knownFailures,idPfx)

    test &"Inspecting {stoLst.len} imported storages lists sub-tries":
      stoLst.test_storageSlotsTries(xdb, db.persistent, knownFailures,idPfx)


proc inspectionRunner(
    noisy = true;
    persistent = true;
    cascaded = true;
    sample: openArray[AccountsSample] = snapTestList) =
  let
    inspectList = sample.mapIt(it.to(seq[UndumpAccounts]))
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(sample[0].name) else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"
    fileInfo = "[" & sample[0].file.splitPath.tail.replace(".txt.gz","") & "..]"

  defer:
    if db.persistent:
      for n in 0 ..< nTestDbInstances:
        if db.cdb[n].rocksStoreRef.isNil:
          break
        db.cdb[n].rocksStoreRef.store.db.rocksdb_close
      tmpDir.flushDbDir(sample[0].name)

  suite &"SyncSnap: inspect {fileInfo} lists for {info} for healing":
    var
      singleStats: seq[(int,TrieNodeStat)]
      accuStats: seq[(int,TrieNodeStat)]
    let
      ingerprinting = &"ingerprinting {inspectList.len}"
      singleAcc = &"F{ingerprinting} single accounts lists"
      accumAcc = &"F{ingerprinting} accumulated accounts"
      cascAcc = &"Cascaded f{ingerprinting} accumulated accounts lists"

      memBase = SnapDbRef.init(newMemoryDB())
      dbSlot = proc(n: int): SnapDbRef =
        if 2+n < nTestDbInstances and not db.cdb[2+n].rocksStoreRef.isNil:
          return SnapDbRef.init(db.cdb[2+n])

    test &"{singleAcc} for in-memory-db":
      inspectList.test_inspectSingleAccountsMemDb(memBase, singleStats)

    test &"{singleAcc} for persistent db":
      if persistent:
        inspectList.test_inspectSingleAccountsPersistent(dbSlot, singleStats)
      else:
        skip()

    test &"{accumAcc} for in-memory-db":
      inspectList.test_inspectAccountsInMemDb(memBase, accuStats)

    test &"{accumAcc} for persistent db":
      if persistent:
        inspectList.test_inspectAccountsPersistent(db.cdb[0], accuStats)
      else:
        skip()

    test &"{cascAcc} for in-memory-db":
      if cascaded:
        inspectList.test_inspectCascadedMemDb()
      else:
        skip()

    test &"{cascAcc} for persistent db":
      if cascaded and persistent:
        inspectList.test_inspectCascadedPersistent(db.cdb[1])
      else:
        skip()

# ------------------------------------------------------------------------------
# Test Runners: database timing tests
# ------------------------------------------------------------------------------

proc importRunner(noisy = true;  persistent = true; capture = bChainCapture) =

  let
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(capture.name) else: testDbs()
    numBlocks = capture.numBlocks
    numBlocksInfo = if numBlocks == high(int): "" else: $numBlocks & " "
    loadNoise = noisy

  defer:
    if db.persistent:
      tmpDir.flushDbDir(capture.name)

  suite &"SyncSnap: using {fileInfo} capture for testing db timings":
    var ddb: CommonRef         # perstent DB on disk

    test &"Create persistent ChainDBRef on {tmpDir}":
      ddb = CommonRef.new(
        db = if db.persistent: db.cdb[0].trieDB else: newMemoryDB(),
        networkId = capture.network,
        pruneTrie = true,
        params = capture.network.networkParams)
      ddb.initializeEmptyDb

    test &"Storing {numBlocksInfo}persistent blocks from dump":
      noisy.test_dbTimingUndumpBlocks(filePath, ddb, numBlocks, loadNoise)

    test "Extract key-value records into memory tables via rocksdb iterator":
      if db.cdb[0].rocksStoreRef.isNil:
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
  elif persistent:
    xTmpDir = getTmpDir()
    xDbs = xTmpDir.testDbs("store-runner")
  else:
    xDbs = testDbs()

  defer:
    if xDbs.persistent and cleanUp:
      for n in 0 ..< nTestDbInstances:
        if xDbs.cdb[n].rocksStoreRef.isNil:
          break
        xDbs.cdb[n].rocksStoreRef.store.db.rocksdb_close
      xTmpDir.flushDbDir("store-runner")
      xDbs.reset

  suite &"SyncSnap: storage tests on {emptyDb} databases":
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

      if xDbs.cdb[0].rocksStoreRef.isNil:
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

proc syncSnapMain*(noisy = defined(debug)) =
  noisy.miscRunner()
  noisy.accountsRunner(persistent=true)
  noisy.accountsRunner(persistent=false)
  noisy.importRunner() # small sample, just verify functionality
  noisy.inspectionRunner()
  noisy.dbTimingRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  #setTraceLevel()
  setErrorLevel()

  # Test constant, calculations etc.
  noisy.miscRunner()

  # This one uses dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_other_xx
    noisy.showElapsed("accountsRunner()"):
      for n,sam in snapOtherList:
        false.accountsRunner(persistent=true, sam)
    noisy.showElapsed("inspectRunner()"):
      for n,sam in snapOtherHealingList:
        false.inspectionRunner(persistent=true, cascaded=false, sam)

  # This one usues dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_storage_xx
    let knownFailures: KnownStorageFailure = @[
      ("storages5__34__41_dump#10", @[( 508, RootNodeMismatch)]),
    ]
    noisy.showElapsed("storageRunner()"):
      for n,sam in snapStorageList:
        false.storagesRunner(persistent=true, sam, knownFailures)

  # This one uses readily available dumps
  when true: # and false:
    false.inspectionRunner()
    for n,sam in snapTestList:
      false.accountsRunner(persistent=false, sam)
      false.accountsRunner(persistent=true, sam)
    for n,sam in snapTestStorageList:
      false.accountsRunner(persistent=false, sam)
      false.accountsRunner(persistent=true, sam)
      false.storagesRunner(persistent=true, sam)

  # This one uses readily available dumps
  when true and false:
    # ---- database storage timings -------

    noisy.showElapsed("importRunner()"):
      noisy.importRunner(capture = bulkTest0)

    noisy.showElapsed("dbTimingRunner()"):
      true.dbTimingRunner(cleanUp = false)
      true.dbTimingRunner()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
