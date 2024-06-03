# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ./test_aristo/[test_filter, test_helpers, test_misc, test_tx]

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

proc miscRunner(noisy = true) =
  suite "Aristo: Miscellaneous tests":

    test "VertexID recyling lists":
      check noisy.testVidRecycleLists()

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

    test &"Delete accounts database successively, {accLst.len} lists":
      check noisy.testTxMergeAndDeleteOneByOne(accLst, dbDir)

    test &"Delete accounts database sub-trees, {accLst.len} lists":
      check noisy.testTxMergeAndDeleteSubTree(accLst, dbDir)

    test &"Distributed backend access {accLst.len} entries":
      check noisy.testDistributedAccess(accLst, dbDir)


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

    test &"Delete storage database successively, {stoLst.len} lists":
      check noisy.testTxMergeAndDeleteOneByOne(stoLst, dbDir)

    test &"Delete storage database sub-trees, {stoLst.len} lists":
      check noisy.testTxMergeAndDeleteSubTree(stoLst, dbDir)

    test &"Distributed backend access {stoLst.len} entries":
      check noisy.testDistributedAccess(stoLst, dbDir)

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

  when true and false:
    # Verify Problem with the database for production test
    noisy.aristoMain()

  # This one uses dumps from the external `nimbus-eth1-blob` repo
  when true and false:
    import ./test_sync_snap/snap_other_xx
    noisy.showElapsed("@snap_other_xx"):
      for n,sam in snapOtherList:
        noisy.accountsRunner(sam, resetDb=true)

  when true: # and false:
    let persistent = false # or true
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
