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

## Re-invented implementation for Merkle Patricia Tree named as Aristo Trie

import
  std/[os, strformat, strutils],
  chronicles,
  eth/[common, p2p],
  rocksdb,
  unittest2,
  ../nimbus/db/select_backend,
  ../nimbus/db/aristo/[aristo_desc],
  ../nimbus/core/chain,
  ../nimbus/sync/snap/worker/db/[
    hexary_desc, rocky_bulk_load, snapdb_accounts, snapdb_desc],
  ./replay/[pp, undump_accounts],
  ./test_sync_snap/[snap_test_xx, test_accounts, test_types],
  ./test_aristo/[test_merge, test_transcode]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests", "nimbus-eth1-blobs"]
  subDir = ["replay", "test_sync_snap", "replay"/"snap"]

  # Reference file for finding the database directory
  sampleDirRefFile = "sample0.txt.gz"

  # Standard test samples
  accSample = snapTest0

  # Number of database slots available
  nTestDbInstances = 9

  # Dormant (may be set if persistent database causes problems)
  disablePersistentDB = false

type
  TestDbs = object
    ## Provide enough spare empty databases
    persistent: bool
    dbDir: string
    baseDir: string # for cleanup
    subDir: string  # for cleanup
    cdb: array[nTestDbInstances,ChainDb]

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
      if db.cdb[n].rocksStoreRef.isNil:
        break
      db.cdb[n].rocksStoreRef.store.db.rocksdb_close
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
      result.cdb[n] = (result.dbDir / $n).newChainDB

proc snapDbRef(cdb: ChainDb; pers: bool): SnapDbRef =
  if pers: SnapDbRef.init(cdb) else: SnapDbRef.init(newMemoryDB())

proc snapDbAccountsRef(cdb:ChainDb; root:Hash256; pers:bool):SnapDbAccountsRef =
  SnapDbAccountsRef.init(cdb.snapDbRef(pers), root, Peer())

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc transcodeRunner(noisy  = true; sample = accSample; stopAfter = high(int)) =
  let
    accLst = sample.to(seq[UndumpAccounts])
    root = accLst[0].root
    tmpDir = getTmpDir()
    db = tmpDir.testDbs(sample.name & "-accounts", instances=2, persistent=true)
    info = if db.persistent: &"persistent db on \"{db.baseDir}\""
           else: "in-memory db"
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    db.flushDbs

  suite &"Aristo: transcoding {fileInfo} accounts for {info}":

    test &"Trancoding VertexID recyling lists (seed={accLst.len})":
      noisy.test_transcodeVidRecycleLists(accLst.len)

    # New common descriptor for this sub-group of tests
    let
      desc = db.cdb[0].snapDbAccountsRef(root, db.persistent)
      hexaDb = desc.hexaDb
      getFn = desc.getAccountFn
      dbg = if noisy: hexaDb else: nil

    # Borrowed from `test_sync_snap/test_accounts.nim`
    test &"Importing {accLst.len} list items to persistent database":
      if db.persistent:
        accLst.test_accountsImport(desc, true)
      else:
        skip()

    test "Trancoding database records: RLP, NodeRef, Blob, VertexRef":
      noisy.showElapsed("test_transcoder()"):
        noisy.test_transcodeAccounts(db.cdb[0].rocksStoreRef, stopAfter)


proc dataRunner(noisy  = true; sample = accSample) =
  let
    accLst = sample.to(seq[UndumpAccounts])
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")

  suite &"Aristo: accounts data import from {fileInfo}":

    test &"Merge {accLst.len} account lists to database":
      noisy.test_mergeAccounts accLst

    test &"Merge {accLst.len} proof & account lists to database":
      noisy.test_mergeProofsAndAccounts accLst


# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc aristoMain*(noisy = defined(debug)) =
  noisy.transcodeRunner()
  noisy.dataRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  # Borrowed from `test_sync_snap.nim`
  when true: # and false:
    for n,sam in snapTestList:
      noisy.transcodeRunner(sam)
    for n,sam in snapTestStorageList:
      noisy.transcodeRunner(sam)

  # This one uses dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_other_xx
    noisy.showElapsed("dataRunner() @snap_other_xx"):
      for n,sam in snapOtherList:
        noisy.dataRunner(sam)

  # This one usues dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_storage_xx
    noisy.showElapsed("dataRunner() @snap_storage_xx"):
      for n,sam in snapStorageList:
        noisy.dataRunner(sam)

  when true: # and false:
    for n,sam in snapTestList:
      noisy.dataRunner(sam)
    for n,sam in snapTestStorageList:
      noisy.dataRunner(sam)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
