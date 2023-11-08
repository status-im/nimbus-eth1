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
  eth/common,
  results,
  unittest2,
  ../nimbus/db/aristo/[aristo_desc, aristo_merge],
  ./replay/[pp, undump_accounts, undump_storages],
  ./test_sync_snap/[snap_test_xx, test_types],
  ./test_aristo/[test_backend, test_filter, test_helpers, test_misc, test_tx]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests", "nimbus-eth1-blobs"]
  subDir = ["replay", "test_sync_snap", "replay"/"snap"]

  # Reference file for finding the database directory
  sampleDirRefFile = "sample0.txt.gz"

  # Standard test samples
  accSample = snapTest0
  storSample = snapTest4

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
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc miscRunner(
    noisy = true;
    qidSampleSize = QidSample;
     ) =

  suite "Aristo: Miscellaneous tests":

    test "VertexID recyling lists":
      check noisy.testVidRecycleLists()

    test &"Low level cascaded fifos API (sample size: {qidSampleSize})":
      check noisy.testQidScheduler(sampleSize = qidSampleSize)

    test &"High level cascaded fifos API (sample size: {qidSampleSize})":
      check noisy.testFilterFifo(sampleSize = qidSampleSize)

    test "Multi instances transactions":
      check noisy.testTxSpanMultiInstances()

    test "Short keys and other patholgical cases":
      check noisy.testShortKeys()


proc accountsRunner(
    noisy = true;
    sample = accSample;
    resetDb = false;
    cmpBackends = true;
    persistent = true;
      ) =
  let
    accLst = sample.to(seq[UndumpAccounts]).to(seq[ProofTrieData])
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")
    listMode = if resetDb: "" else: ", merged dumps"
    baseDir = getTmpDir() / sample.name & "-accounts"
    dbDir = if persistent: baseDir / "tmp" else: ""
    isPersistent = if persistent: "persistent DB" else: "mem DB only"

  defer:
    try: baseDir.removeDir except CatchableError: discard

  suite &"Aristo: accounts data dump from {fileInfo}{listMode}, {isPersistent}":

    test &"Merge {accLst.len} proof & account lists to database":
      check noisy.testTxMergeProofAndKvpList(accLst, dbDir, resetDb)

    test &"Compare {accLst.len} account lists on different database backends":
      if cmpBackends and 0 < dbDir.len:
        check noisy.testBackendConsistency(accLst, dbDir, resetDb)
      else:
        skip()

    test &"Delete accounts database, successively {accLst.len} entries":
      check noisy.testTxMergeAndDelete(accLst, dbDir)

    test &"Distributed backend access {accLst.len} entries":
      check noisy.testDistributedAccess(accLst, dbDir)

    test &"Filter backlog management {accLst.len} entries":
      check noisy.testFilterBacklog(accLst, rdbPath=dbDir)


proc storagesRunner(
    noisy = true;
    sample = storSample;
    resetDb = false;
    oops: KnownHasherFailure = @[];
    cmpBackends = true;
    persistent = true;
      ) =
  let
    stoLst = sample.to(seq[UndumpStorages]).to(seq[ProofTrieData])
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")
    listMode = if resetDb: "" else: ", merged dumps"
    baseDir = getTmpDir() / sample.name & "-storage"
    dbDir = if persistent: baseDir / "tmp" else: ""
    isPersistent = if persistent: "persistent DB" else: "mem DB only"

  defer:
    try: baseDir.removeDir except CatchableError: discard

  suite &"Aristo: storages data dump from {fileInfo}{listMode}, {isPersistent}":

    test &"Merge {stoLst.len} proof & slots lists to database":
      check noisy.testTxMergeProofAndKvpList(
        stoLst, dbDir, resetDb, fileInfo, oops)

    test &"Compare {stoLst.len} slot lists on different database backends":
      if cmpBackends and 0 < dbDir.len:
        check noisy.testBackendConsistency(stoLst, dbDir, resetDb)
      else:
        skip()

    test &"Delete storage database, successively {stoLst.len} entries":
      check noisy.testTxMergeAndDelete(stoLst, dbDir)

    test &"Distributed backend access {stoLst.len} entries":
      check noisy.testDistributedAccess(stoLst, dbDir)

    test &"Filter backlog management {stoLst.len} entries":
      check noisy.testFilterBacklog(stoLst, rdbPath=dbDir)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc aristoMain*(noisy = defined(debug)) =
  noisy.miscRunner()
  noisy.accountsRunner()
  noisy.storagesRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  setErrorLevel()

  when true: # and false:
    noisy.miscRunner(qidSampleSize = 1_000)

  # This one uses dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_other_xx
    noisy.showElapsed("@snap_other_xx"):
      for n,sam in snapOtherList:
        noisy.accountsRunner(sam, resetDb=true)

  # This one usues dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_storage_xx
    let knownFailures: KnownHasherFailure = @[
      ("storages3__18__25_dump#12.27367",(3,HashifyExistingHashMismatch)),
      ("storages4__26__33_dump#12.23924",(6,HashifyExistingHashMismatch)),
      ("storages5__34__41_dump#10.20512",(1,HashifyRootHashMismatch)),
      ("storagesB__84__92_dump#7.9709",  (7,HashifyExistingHashMismatch)),
      ("storagesD_102_109_dump#18.28287",(9,HashifyExistingHashMismatch)),
    ]
    noisy.showElapsed("@snap_storage_xx"):
      for n,sam in snapStorageList:
        noisy.accountsRunner(sam, resetDb=true)
        noisy.storagesRunner(sam, resetDb=true, oops=knownFailures)

  when true: # and false:
    let persistent = false
    noisy.showElapsed("@snap_test_list"):
      for n,sam in snapTestList:
        noisy.accountsRunner(sam, persistent=persistent)
    noisy.showElapsed("@snap_test_storage_list"):
      for n,sam in snapTestStorageList:
        noisy.accountsRunner(sam, persistent=persistent)
        noisy.storagesRunner(sam, persistent=persistent)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
