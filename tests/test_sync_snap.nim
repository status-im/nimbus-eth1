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

## Snap sync components tester

import
  std/[distros, os, sequtils, strformat, strutils],
  chronicles,
  eth/[common/eth_types, p2p, rlp, trie/db],
  stint,
  stew/results,
  unittest2,
  ../nimbus/db/select_backend,
  ../nimbus/sync/[types, protocol],
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/accounts_db,
  ./replay/pp,
  #./test_sync_snap/sample1,
  ./test_sync_snap/sample0

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = ["tests"/"replay", "tests"/"test_sync_snap"]

type
  TestSample = tuple ## sample format from `accounts_and_proofs`
    base: Hash256
    accounts: seq[(Hash256,uint64,UInt256,Hash256,Hash256)]
    proofs: seq[Blob]

  TestItem = object ## palatable input format for tests
    base: NodeTag
    data: SnapAccountRange

  TestDbInstances =
    array[3,TrieDatabaseRef]

  TestDbs = object
    persistent: bool
    dbDir: string
    inst: TestDbInstances

when defined(linux):
  # The `detectOs(Ubuntu)` directive is not Windows compatible, causes an
  # error when running the system command `lsb_release -d` in the background.
  let isUbuntu32bit = detectOs(Ubuntu) and int.sizeof == 4
else:
  const isUbuntu32bit = false

let
  # Forces `check()` to print the error (as opposed when using `isOk()`)
  OkAccDb = Result[void,AccountsDbError].ok()

  # There was a problem with the Github/CI which results in spurious crashes
  # when leaving the `runner()` if the persistent BaseChainDB initialisation
  # was present, see `test_custom_network` for more details.
  disablePersistentDB = isUbuntu32bit

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string): Result[string,void] =
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return ok(path)
  err()

proc pp(w: Hash256): string =
  pp.pp(w) # `pp()` also available from `worker_desc`

proc pp(w: NodeTag; collapse = true): string =
  pp.pp(w.to(Hash256),collapse)

proc pp(w: seq[(string,string)]; indent = 4): string =
  w.mapIt(&"({it[0]},{it[1]})").join("\n" & " ".repeat(indent))

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

proc to(data: seq[TestSample]; T: type seq[TestItem]): T =
  ## Convert test data into usable format
  for r in  data:
    result.add TestItem(
      base:       r.base.to(NodeTag),
      data:       SnapAccountRange(
        proof:    r.proofs,
        accounts: r.accounts.mapIt(
          SnapAccount(
            accHash:       it[0],
            accBody: Account(
              nonce:       it[1],
              balance:     it[2],
              storageRoot: it[3],
              codeHash:    it[4])))))

#proc permute(r: var Rand; qLen: int): seq[int]  =
#  result = (0 ..< qLen).toSeq
#  let
#    halfLen = result.len shr 1
#    randMax = result.len - halfLen - 1
#  for left in 0 ..< halfLen:
#    let right = halfLen + r.rand(randMax)
#    result[left].swap(result[right])

proc flushDbDir(s: string) =
  if s != "":
    let baseDir = s / "tmp"
    for n in 0 ..< TestDbInstances.len:
      let instDir = baseDir / $n
      if (instDir / "nimbus" / "data").dirExists:
        # Typically under Windows: there might be stale file locks.
        try: instDir.removeDir except: discard
    block dontClearUnlessEmpty:
      for w in baseDir.walkDir:
        break dontClearUnlessEmpty
      try: baseDir.removeDir except: discard

proc testDbs(workDir = ""): TestDbs =
  if disablePersistentDB or workDir == "":
    result.persistent = false
    result.dbDir = "*notused*"
  else:
    result.persistent = true
    result.dbDir = workDir / "tmp"
  if result.persistent:
    result.dbDir.flushDbDir
  for n in 0 ..< result.inst.len:
    if not result.persistent:
      result.inst[n] = newMemoryDB()
    else:
      result.inst[n] = (result.dbDir / $n).newChainDB.trieDB

proc lastTwo(a: openArray[string]): seq[string] =
  if 1 < a.len: @[a[^2],a[^1]] else: a.toSeq

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc accountsRunner(
    noisy = true;  persistent: bool; root: Hash256; data: seq[TestSample]) =
  let
    peer = Peer.new
    testItemLst = data.to(seq[TestItem])
    tmpDir = "sample0.nim".findFilePath.value.splitFile.dir
    db = if persistent: tmpDir.testDbs() else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"

  defer:
    if db.persistent:
      tmpDir.flushDbDir

  suite &"SyncSnap: accounts and proofs for {info}":
    var
      base: AccountsDbRef
      desc: AccountsDbSessionRef

    test &"Verifying {testItemLst.len} snap items for state root ..{root.pp}":
      base = AccountsDbRef.init(db.inst[0])
      for n,w in testItemLst:
        check base.importAccounts(peer, root, w.base, w.data) == OkAccDb

    test &"Merging {testItemLst.len} proofs for state root ..{root.pp}":
      base = AccountsDbRef.init(db.inst[1])
      desc = AccountsDbSessionRef.init(base, root, peer)
      for n,w in testItemLst:
        check desc.merge(w.data.proof) == OkAccDb
        check desc.merge(w.base, w.data.accounts) == OkAccDb
        desc.assignPrettyKeys() # for debugging (if any)
        check desc.interpolate() == OkAccDb

      # echo ">>> ", desc.dumpProofsDB.join("\n    ")

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc syncSnapMain*(noisy = defined(debug)) =
  noisy.accountsRunner(
    persistent = false, sample0.snapRoot, sample0.snapProofData)

when isMainModule:
  const
    noisy = defined(debug) or true
    test00 = (sample0.snapRoot, @[sample0.snapProofData0])
    test01 = (sample0.snapRoot, sample0.snapProofData)
    #test10 = (sample1.snapRoot, @[sample1.snapProofData1])
    #test11 = (sample1.snapRoot, sample1.snapProofData)

  setTraceLevel()
  setErrorLevel()

  noisy.accountsRunner(persistent=false, test00[0], test00[1])
  noisy.accountsRunner(persistent=false, test01[0], test01[1])
  #noisy.accountsRunner(persistent=false, test10[0], test10[1])
  #noisy.accountsRunner(persistent=false, test11[0], test11[1])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
