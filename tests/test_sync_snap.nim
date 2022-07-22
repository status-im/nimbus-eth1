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
  std/[distros, os, random, sequtils, strformat, strutils],
  chronicles,
  eth/[common/eth_types, p2p, rlp, trie/db, trie/hexary],
  stint,
  stew/results,
  unittest2,
  ../nimbus/db/select_backend,
  ../nimbus/sync/[types, protocol/snap1],
  ../nimbus/sync/snap/path_desc,
  ../nimbus/sync/snap/worker/[fetch/proof_db, worker_desc],
  ./replay/pp,
  ./test_sync_snap/accounts_and_proofs

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
    data: WorkerAccountRange

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
  OkPmt = Result[void,PmtError].ok()

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

proc pp(w: TrieHash): string =
  pp.pp(w.Hash256) # `pp()` also available from `worker_desc`

proc pp(w: NodeTag; collapse = true): string =
  pp.pp(w.to(Hash256),collapse)

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
      data:       WorkerAccountRange(
        proof:    r.proofs,
        accounts: r.accounts.mapIt(
          SnapAccount(
            accHash:       it[0].to(NodeTag),
            accBody: Account(
              nonce:       it[1],
              balance:     it[2],
              storageRoot: it[3],
              codeHash:    it[4])))))

proc permute(r: var Rand; qLen: int): seq[int]  =
  result = (0 ..< qLen).toSeq
  let
    halfLen = result.len shr 1
    randMax = result.len - halfLen - 1
  for left in 0 ..< halfLen:
    let right = halfLen + r.rand(randMax)
    result[left].swap(result[right])

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
    noisy = true;  persistent: bool; root: TrieHash; data: seq[TestSample]) =
  let
    peer = Peer.new
    lst = data.to(seq[TestItem])
    tmpDir = "accounts_and_proofs.nim".findFilePath.value.splitFile.dir
    db = if persistent: tmpDir.testDbs() else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"

  defer:
    if db.persistent:
      tmpDir.flushDbDir

  suite &"SyncSnap: accounts and proofs for {info}":
    var
      desc: ProofDb
      nRows: seq[int]

    test &"Merging {lst.len} proofs for state root ..{root.pp}":
      desc.init(db.inst[0])
      check desc.mergeBegin(peer, root)
      for proofs in lst.mapIt(it.data.proof):
        check desc.merge(proofs) == OkPmt
        check desc.mergeValidate == OkPmt
        nRows.add desc.nPmts(root)
      check 1 < nRows.len # otherwise test makes no sense
      check 0 < nRows[^1]

    test "Rollback full database":
      check desc.mergeRollback()
      check desc.nPmts(root) == 0
      check desc.nAccounts(root) == 0
      check desc.journalSize == (false,0,0,0)

    test "Merging and committing all except the last":
      for n,proofs in lst.mapIt(it.data.proof):
        check desc.mergeBegin(peer, root)
        check desc.merge(proofs) == OkPmt
        check nRows[n] == desc.nPmts(root)
        check desc.mergeValidate == OkPmt
        if n < nRows.len - 1:
          check desc.mergeCommit
        check nRows[n] == desc.nPmts(root)
      check desc.mergeRollback
      check 1 < nRows.len and nRows[^2] == desc.nPmts(root)

    test &"Merging/committing {lst.len} proofs, transposed rows":
      desc.init(db.inst[1])
      check desc.nPmts(root) == 0
      check desc.journalSize == (false,0,0,0)
      var r = initRand(42)
      for n,proofs in lst.mapIt(it.data.proof):
        let permPmt = r.permute(proofs.len).mapIt(proofs[it])
        check desc.mergeBegin(peer, root)
        check desc.merge(permPmt) == OkPmt
        check desc.mergeValidate == OkPmt
        check desc.mergeCommit
        check nRows[n] == desc.nPmts(root)

    test &"Merging {lst.len} account groups for state root ..{root.pp}":
      desc.init(db.inst[2])
      for n,w in lst:
        check desc.mergeProved(peer, root, w.base, w.data) == OkPmt
        check desc.journalSize == (false,0,0,0)
        check nRows[n] == desc.nPmts(root)
        check desc.journalSize == (false,0,0,0)
      check 1 < nRows.len # otherwise test makes no sense
      check 0 < nRows[^1]

    test &"Visiting {desc.nAccounts(root)} accounts":
      var
        nItems = desc.nAccounts(root)
        nProved = 0
        htr = db.inst[2].initHexaryTrie(root.Hash256)

      check 1 < nItems
      for (n, key, accData) in desc.accounts(root):
        check nItems == n
        nItems.dec
        if accData.proved:
          nProved.inc

          # Fetch/verify data from hexary trie
          let blob = htr.get(key.to(Hash256).data)
          check 0 < blob.len
          check accData.account == blob.decode(Account)

      check nItems == 0
      # each group has exactly one proved account
      check nProved == lst.len

    test "Visiting single root":
      var nItems = desc.nStateRoots
      check 0 < nItems
      for (n,tag) in desc.stateRoots:
        check nItems == n
        nItems.dec
      check nItems == 0

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc syncSnapMain*(noisy = defined(debug)) =
  noisy.accountsRunner(persistent = true, testRoot.TrieHash, testSamples)

when isMainModule:
  const noisy = defined(debug) or true

  when true: # false:
    # Import additional data from test data repo
    import ../../nimbus-eth1-blobs/replay/accounts_and_proofs_ex
  else:
    const
      testRootEx = testRoot
      testSamplesEx = newSeq[TestSample]()

  setTraceLevel()

  # Verify sample state roots
  doAssert testRoot == testRootEx

  let samplesList = (testSamples & testSamplesEx)
  noisy.accountsRunner(persistent = true, testRoot.TrieHash, samplesList)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
