# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ../execution_chain/db/aristo/aristo_desc,
  ./replay/pp,
  ./test_aristo/test_blobify,
  ./test_aristo/test_merge_proof,
  ./test_aristo/test_nibbles,
  ./test_aristo/test_portal_proof,
  ./test_aristo/test_compute,
  ./test_aristo/[
    test_helpers, test_samples_xx, test_tx,
    undump_accounts, undump_storages]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"]
  subDir = ["replay", "test_aristo", "replay"/"snap"]

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

proc accountsRunner(
    noisy = true;
    sample = accSample;
    cmpBackends = true;
    persistent = true;
      ) =
  let
    accLst = sample.to(seq[UndumpAccounts]).to(seq[ProofTrieData])
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")
    baseDir = getTmpDir() / sample.name & "-accounts"
    dbDir = if persistent: baseDir / "tmp" else: ""
    isPersistent = if persistent: "persistent DB" else: "mem DB only"

  defer:
    try: baseDir.removeDir except CatchableError: discard

  suite &"Aristo: accounts data dump from {fileInfo}, {isPersistent}":

    test &"Merge {accLst.len} proof & account lists to database":
      check noisy.testMergeProofAndKvpList(accLst, dbDir)

    test &"Delete accounts database successively, {accLst.len} lists":
      check noisy.testTxMergeAndDeleteOneByOne(accLst, dbDir)

    test &"Delete accounts database sub-trees, {accLst.len} lists":
      check noisy.testTxMergeAndDeleteSubTree(accLst, dbDir)


proc storagesRunner(
    noisy = true;
    sample = storSample;
    cmpBackends = true;
    persistent = true;
      ) =
  let
    stoLst = sample.to(seq[UndumpStorages]).to(seq[ProofTrieData])
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")
    baseDir = getTmpDir() / sample.name & "-storage"
    dbDir = if persistent: baseDir / "tmp" else: ""
    isPersistent = if persistent: "persistent DB" else: "mem DB only"

  defer:
    try: baseDir.removeDir except CatchableError: discard

  suite &"Aristo: storages data dump from {fileInfo}, {isPersistent}":

    test &"Merge {stoLst.len} proof & slot lists to database":
      check noisy.testMergeProofAndKvpList(stoLst, dbDir, fileInfo)

    test &"Delete storage database successively, {stoLst.len} lists":
      check noisy.testTxMergeAndDeleteOneByOne(stoLst, dbDir)

    test &"Delete storage database sub-trees, {stoLst.len} lists":
      check noisy.testTxMergeAndDeleteSubTree(stoLst, dbDir)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc aristoMain*(noisy = defined(debug)) =
  noisy.storagesRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

  setErrorLevel()

  when true and false:
    # Verify Problem with the database for production test
    noisy.aristoMain()

  when true: # and false:
    let persistent = false # or true
    noisy.showElapsed("@snap_test_list"):
      for n,sam in snapTestList:
        noisy.accountsRunner(sam, persistent=persistent)
    noisy.showElapsed("@snap_test_storage_list"):
      for n,sam in snapTestStorageList:
        noisy.accountsRunner(sam, persistent=persistent)
        noisy.storagesRunner(sam, persistent=persistent)
else:
  aristoMain()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
