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
  std/[os, sets, sequtils, strformat, strutils, tables],
  chronicles,
  eth/[common, p2p],
  rocksdb,
  unittest2,
  ../nimbus/db/[core_db, kvstore_rocksdb],
  ../nimbus/db/core_db/[legacy_rocksdb, persistent],
  ../nimbus/core/chain,
  ../nimbus/sync/types,
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_envelope, hexary_error, hexary_inspect, hexary_nearby,
    hexary_paths, rocky_bulk_load, snapdb_accounts, snapdb_debug, snapdb_desc],
  ./replay/[pp, undump_accounts, undump_storages],
  ./test_sync_snap/[
    snap_test_xx,
    test_accounts, test_calc, test_helpers, test_node_range, test_inspect,
    test_pivot, test_storage, test_syncdb, test_types]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests", "nimbus-eth1-blobs"]
  subDir = ["replay", "test_sync_snap", "replay"/"snap"]

  # Reference file for finding the database directory
  sampleDirRefFile = "sample0.txt.gz"

  # Standard test samples
  accSample = snapTest0
  storSample = snapTest4

  # Number of database slots available
  nTestDbInstances = 9

type
  TestDbs = object
    ## Provide enough spare empty databases
    persistent: bool
    dbDir: string
    baseDir: string # for cleanup
    subDir: string  # for cleanup
    cdb: array[nTestDbInstances,CoreDbRef]

  SnapRunDesc = object
    id: int
    info: string
    file: string
    chn: ChainRef

var
  xTmpDir: string
  xDbs: TestDbs                   # for repeated storage/overwrite tests

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

proc to(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
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
  let file = sample.file.findFilePath.value
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
  if workDir == "" or not persistent:
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

proc snapDbRef(cdb: CoreDbRef; pers: bool): SnapDbRef =
  if pers: SnapDbRef.init(cdb)
  else: SnapDbRef.init(newCoreDbRef LegacyDbMemory)

proc snapDbAccountsRef(
    cdb: CoreDbRef;
    root: Hash256;
    pers: bool;
      ):SnapDbAccountsRef =
  SnapDbAccountsRef.init(cdb.snapDbRef(pers), root, Peer())

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc accountsRunner(noisy = true;  persistent = true; sample = accSample) =
  let
    accLst = sample.to(seq[UndumpAccounts])
    root = accLst[0].root
    tmpDir = getTmpDir()
    db = tmpDir.testDbs(sample.name & "-accounts", instances=3, persistent)
    info = if db.persistent: &"persistent db on \"{db.baseDir}\""
           else: "in-memory db"
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    db.flushDbs

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
      hexaDb.assignPrettyKeys(root.to(NodeKey))

      # Beware: dumping a large database is not recommended
      # true.say "***", "database dump\n    ", hexaDb.pp(root.to(NodeKey))

      test &"Retrieve accounts & proofs for previous account ranges":
        if db.persistent:
          accLst.test_NodeRangeProof(getFn, dbg)
        else:
          accLst.test_NodeRangeProof(hexaDb, dbg)

      test &"Verify left boundary checks":
        if db.persistent:
          accLst.test_NodeRangeLeftBoundary(getFn, dbg)
        else:
          accLst.test_NodeRangeLeftBoundary(hexaDb, dbg)

    block:
      # List of keys to be shared by sub-group
      var accKeys: seq[NodeKey]

      # New common descriptor for this sub-group of tests
      let desc = db.cdb[1].snapDbAccountsRef(root, db.persistent)

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

      # This one works with a new clean database in order to avoid some
      # problems on observed qemu/Win7.
      test &"Storing/retrieving {accKeys.len} stored items " &
          "on persistent pivot/checkpoint registry":
        if db.persistent:
          accKeys.test_pivotStoreRead(db.cdb[2])
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
    db = tmpDir.testDbs(sample.name & "-storages", instances=1, persistent)
    info = if db.persistent: &"persistent db" else: "in-memory db"
    idPfx = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    db.flushDbs

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
    db = tmpDir.testDbs(
      sample[0].name & "-inspection", instances=nTestDbInstances, persistent)
    info = if db.persistent: &"persistent db" else: "in-memory db"
    fileInfo = "[" & sample[0].file.splitPath.tail.replace(".txt.gz","") & "..]"

  defer:
    db.flushDbs

  suite &"SyncSnap: inspect {fileInfo} lists for {info} for healing":
    var
      singleStats: seq[(int,TrieNodeStat)]
      accuStats: seq[(int,TrieNodeStat)]
    let
      ingerprinting = &"ingerprinting {inspectList.len}"
      singleAcc = &"F{ingerprinting} single accounts lists"
      accumAcc = &"F{ingerprinting} accumulated accounts"
      cascAcc = &"Cascaded f{ingerprinting} accumulated accounts lists"

      memBase = SnapDbRef.init(newCoreDbRef LegacyDbMemory)
      dbSlot = proc(n: int): SnapDbRef =
        if 2+n < nTestDbInstances and
           not db.cdb[2+n].backend.toRocksStoreRef.isNil:
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
# Other test Runners
# ------------------------------------------------------------------------------

proc miscRunner(noisy = true) =
  suite "SyncSnap: Verify setup, constants, limits":

    test "RLP accounts list sizes":
      test_calcAccountsListSizes()

    test "RLP proofs list sizes":
      test_calcProofsListSizes()

    test "RLP en/decode GetTrieNodes arguments list":
      test_calcTrieNodeTranscode()

    test "RLP en/decode BockBody arguments list":
      test_calcBlockBodyTranscode()


proc snapRunner(noisy = true; specs: SnapSyncSpecs) =
  let
    tailInfo = specs.tailBlocks.splitPath.tail.replace(".txt.gz","")
    tailPath = specs.tailBlocks.findFilePath.value
    allFile = "mainnet332160.txt.gz".findFilePath.value

    pivot = specs.pivotBlock
    updateSize = specs.nItems

    tmpDir = getTmpDir()
    db = tmpDir.testDbs(specs.name, instances=1, true)

  defer:
    db.flushDbs()

  var dsc = SnapRunDesc(
    info: specs.snapDump.splitPath.tail.replace(".txt.gz",""),
    file: specs.snapDump.findFilePath.value,
    chn: CommonRef.new(
      db.cdb[0],
      networkId = specs.network,
      pruneTrie = true,
      params = specs.network.networkParams).newChain)

  dsc.chn.com.initializeEmptyDB()

  suite &"SyncSnap: verify \"{dsc.info}\" snapshot against full sync":

    #test "Import block chain":
    #  if dsc.chn.db.toLegacyBackend.rocksStoreRef.isNil:
    #    skip()
    #  else:
    #    noisy.showElapsed("import block chain"):
    #      check dsc.chn.test_syncdbImportChainBlocks(allFile, pivot) == pivot
    #    noisy.showElapsed("dump db"):
    #      dsc[1].chn.db.toLegacyBackend.rocksStoreRef.dumpAllDb()

    test "Import snapshot dump":
      if dsc.chn.db.backend.toRocksStoreRef.isNil:
        skip()
      else:
        noisy.showElapsed(&"undump \"{dsc.info}\""):
          let
            (a,b,c) = dsc.chn.test_syncdbImportSnapshot(dsc.file, noisy=noisy)
            aSum = a[0] + a[1]
            bSum = b.foldl(a + b)
            cSum = c.foldl(a + b)
          noisy.say "***", "[", dsc.info, "]",
            " undumped ", aSum + bSum + cSum, " snapshot records",
            " (key32=", aSum, ",",
            " key33=", bSum, ",",
            " other=", cSum, ")" #, " b=",b.pp, " c=", c.pp
        when false: # or true:
          noisy.showElapsed(&"dump db \"{dsc.info}\""):
            dsc.chn.db.toLegacyBackend.rocksStoreRef.dumpAllDb()

      test &"Append block chain from \"{tailInfo}\"":
        if dsc.chn.db.backend.toRocksStoreRef.isNil:
          skip()
        else:
          dsc.chn.db.compensateLegacySetup
          dsc.chn.test_syncdbAppendBlocks(tailPath,pivot,updateSize,noisy)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc syncSnapMain*(noisy = defined(debug)) =
  noisy.miscRunner()
  noisy.accountsRunner(persistent=true)
  noisy.accountsRunner(persistent=false)
  noisy.inspectionRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  #setTraceLevel()
  setErrorLevel()

  # Test constants, calculations etc.
  when true: # and false:
    noisy.miscRunner()

  # Test database snapshot handling. The test samples ate too big for
  # `nimbus-eth1` so they are available on `nimbus-eth1-blobs.`
  when true: # or false
    import ./test_sync_snap/snap_syncdb_xx
    for n,sam in snapSyncdbList:
      false.snapRunner(sam)

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
