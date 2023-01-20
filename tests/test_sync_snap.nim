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
  std/[algorithm, distros, os, sets, sequtils, strformat, strutils, tables],
  chronicles,
  eth/[common, p2p, rlp, trie/nibbles],
  rocksdb,
  unittest2,
  ../nimbus/common/common as nimbus_common, # avoid name clash
  ../nimbus/db/[select_backend, storage_types],
  ../nimbus/core/chain,
  ../nimbus/sync/types,
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_envelope, hexary_error, hexary_inspect, hexary_nearby,
    hexary_paths, rocky_bulk_load, snapdb_accounts, snapdb_desc, snapdb_pivot,
    snapdb_storage_slots],
  ./replay/[pp, undump_accounts, undump_storages],
  ./test_sync_snap/[
    bulk_test_xx, snap_test_xx,
    test_decompose, test_inspect, test_db_timing, test_types]

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
  # Forces `check()` to print the error (as opposed when using `isOk()`)
  OkHexDb = Result[void,HexaryError].ok()
  OkStoDb = Result[void,seq[(int,HexaryError)]].ok()

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

proc isImportOk(rc: Result[SnapAccountsGaps,HexaryError]): bool =
  if rc.isErr:
    check rc.error == NothingSerious # prints an error if different
  elif 0 < rc.value.innerGaps.len:
    check rc.value.innerGaps == seq[NodeSpecs].default
  else:
    return true

proc toStoDbRc(r: seq[HexaryNodeReport]): Result[void,seq[(int,HexaryError)]]=
  ## Kludge: map error report to (older version) return code
  if r.len != 0:
    return err(r.mapIt((it.slot.get(otherwise = -1),it.error)))
  ok()

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

proc pp(rc: Result[Account,HexaryError]): string =
  if rc.isErr: $rc.error else: rc.value.pp

proc pp(rc: Result[Hash256,HexaryError]): string =
  if rc.isErr: $rc.error else: $rc.value.to(NodeTag)

proc pp(rc: Result[TrieNodeStat,HexaryError]; db: SnapDbBaseRef): string =
  if rc.isErr: $rc.error else: rc.value.pp(db.hexaDb)

proc pp(a: NodeKey; collapse = true): string =
  a.to(Hash256).pp(collapse)

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

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

proc to(b: openArray[byte]; T: type ByteArray32): T =
  ## Convert to other representation (or exception)
  if b.len == 32:
    (addr result[0]).copyMem(unsafeAddr b[0], 32)
  else:
    doAssert b.len == 32

proc to(b: openArray[byte]; T: type ByteArray33): T =
  ## Convert to other representation (or exception)
  if b.len == 33:
    (addr result[0]).copyMem(unsafeAddr b[0], 33)
  else:
    doAssert b.len == 33

proc to(b: ByteArray32|ByteArray33; T: type Blob): T =
  b.toSeq

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

proc lastTwo(a: openArray[string]): seq[string] =
  if 1 < a.len: @[a[^2],a[^1]] else: a.toSeq

proc flatten(list: openArray[seq[Blob]]): seq[Blob] =
  for w in list:
    result.add w

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc accountsRunner(noisy = true;  persistent = true; sample = accSample) =
  let
    peer = Peer.new
    accountsList = sample.to(seq[UndumpAccounts])
    root = accountsList[0].root
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
    var
      desc: SnapDbAccountsRef
      accKeys: seq[NodeKey]

    test &"Snap-proofing {accountsList.len} items for state root ..{root.pp}":
      let
        dbBase = if persistent: SnapDbRef.init(db.cdb[0])
                 else: SnapDbRef.init(newMemoryDB())
        dbDesc = SnapDbAccountsRef.init(dbBase, root, peer)
      for n,w in accountsList:
        check dbDesc.importAccounts(w.base, w.data, persistent).isImportOk

    test &"Merging {accountsList.len} proofs for state root ..{root.pp}":
      let dbBase = if persistent: SnapDbRef.init(db.cdb[1])
                   else: SnapDbRef.init(newMemoryDB())
      desc = SnapDbAccountsRef.init(dbBase, root, peer)

      # Load/accumulate data from several samples (needs some particular sort)
      let baseTag = accountsList.mapIt(it.base).sortMerge
      let packed = PackedAccountRange(
        accounts: accountsList.mapIt(it.data.accounts).sortMerge,
        proof:    accountsList.mapIt(it.data.proof).flatten)
      # Merging intervals will produce gaps, so the result is expected OK but
      # different from `.isImportOk`
      check desc.importAccounts(baseTag, packed, true).isOk

      # check desc.merge(lowerBound, accounts) == OkHexDb
      desc.assignPrettyKeys() # for debugging, make sure that state root ~ "$0"

      # Update list of accounts. There might be additional accounts in the set
      # of proof nodes, typically before the `lowerBound` of each block. As
      # there is a list of account ranges (that were merged for testing), one
      # need to check for additional records only on either end of a range.
      var keySet = packed.accounts.mapIt(it.accKey).toHashSet
      for w in accountsList:
        var key = desc.prevAccountsChainDbKey(w.data.accounts[0].accKey)
        while key.isOk and key.value notin keySet:
          keySet.incl key.value
          let newKey = desc.prevAccountsChainDbKey(key.value)
          check newKey != key
          key = newKey
        key = desc.nextAccountsChainDbKey(w.data.accounts[^1].accKey)
        while key.isOk and key.value notin keySet:
          keySet.incl key.value
          let newKey = desc.nextAccountsChainDbKey(key.value)
          check newKey != key
          key = newKey
      accKeys = toSeq(keySet).mapIt(it.to(NodeTag)).sorted(cmp)
                             .mapIt(it.to(NodeKey))
      check packed.accounts.len <= accKeys.len

    test &"Revisiting {accKeys.len} items stored items on ChainDBRef":
      var
        nextAccount = accKeys[0]
        prevAccount: NodeKey
        count = 0
      for accKey in accKeys:
        count.inc
        let
          pfx = $count & "#"
          byChainDB = desc.getAccountsChainDb(accKey)
          byNextKey = desc.nextAccountsChainDbKey(accKey)
          byPrevKey = desc.prevAccountsChainDbKey(accKey)
        noisy.say "*** find",
          "<", count, "> byChainDb=", byChainDB.pp
        check byChainDB.isOk

        # Check `next` traversal funcionality. If `byNextKey.isOk` fails, the
        # `nextAccount` value is still the old one and will be different from
        # the account in the next for-loop cycle (if any.)
        check pfx & accKey.pp(false) == pfx & nextAccount.pp(false)
        if byNextKey.isOk:
          nextAccount = byNextKey.get(otherwise = NodeKey.default)

        # Check `prev` traversal funcionality
        if prevAccount != NodeKey.default:
          check byPrevKey.isOk
          if byPrevKey.isOk:
            check pfx & byPrevKey.value.pp(false) == pfx & prevAccount.pp(false)
        prevAccount = accKey

      # Hexary trie memory database dump. These are key value pairs for
      # ::
      #   Branch:    ($1,b(<$2,$3,..,$17>,))
      #   Extension: ($18,e(832b5e..06e697,$19))
      #   Leaf:      ($20,l(cc9b5d..1c3b4,f84401..f9e5129d[#70]))
      #
      # where keys are typically represented as `$<id>` or `¶<id>` or `ø`
      # depending on whether a key is final (`$<id>`), temporary (`¶<id>`)
      # or unset/missing (`ø`).
      #
      # The node types are indicated by a letter after the first key before
      # the round brackets
      # ::
      #   Branch:    'b', 'þ', or 'B'
      #   Extension: 'e', '€', or 'E'
      #   Leaf:      'l', 'ł', or 'L'
      #
      # Here a small letter indicates a `Static` node which was from the
      # original `proofs` list, a capital letter indicates a `Mutable` node
      # added on the fly which might need some change, and the decorated
      # letters stand for `Locked` nodes which are like `Static` ones but
      # added later (typically these nodes are update `Mutable` nodes.)
      #
      # Beware: dumping a large database is not recommended
      #true.say "***", "database dump\n    ", desc.dumpHexaDB()

    test &"Decompose path prefix envelopes on {info}":
      if db.persistent:
        # Store accounts persistent accounts DB
        accKeys.test_decompose(root.to(NodeKey), desc.getAccountFn, desc.hexaDB)
      else:
        accKeys.test_decompose(root.to(NodeKey), desc.hexaDB, desc.hexaDB)

    test &"Storing/retrieving {accKeys.len} items " &
        "on persistent pivot/checkpoint registry":
      if not persistent:
        skip()
      else:
        let
          dbBase = SnapDbRef.init(db.cdb[0])
          processed = @[(1.to(NodeTag),2.to(NodeTag)),
                        (4.to(NodeTag),5.to(NodeTag)),
                        (6.to(NodeTag),7.to(NodeTag))]
          slotAccounts = seq[NodeKey].default
        for n,w in accKeys:
          check dbBase.savePivot(
            SnapDbPivotRegistry(
              header:       BlockHeader(stateRoot: w.to(Hash256)),
              nAccounts:    n.uint64,
              nSlotLists:   n.uint64,
              processed:    processed,
              slotAccounts: slotAccounts)).isOk
          # verify latest state root
          block:
            let rc = dbBase.recoverPivot()
            check rc.isOk
            if rc.isOk:
              check rc.value.nAccounts == n.uint64
              check rc.value.nSlotLists == n.uint64
              check rc.value.processed == processed
        for n,w in accKeys:
          block:
            let rc = dbBase.recoverPivot(w)
            check rc.isOk
            if rc.isOk:
              check rc.value.nAccounts == n.uint64
              check rc.value.nSlotLists == n.uint64
          # Update record in place
          check dbBase.savePivot(
            SnapDbPivotRegistry(
              header:       BlockHeader(stateRoot: w.to(Hash256)),
              nAccounts:    n.uint64,
              nSlotLists:   0,
              processed:    @[],
              slotAccounts: @[])).isOk
          block:
            let rc = dbBase.recoverPivot(w)
            check rc.isOk
            if rc.isOk:
              check rc.value.nAccounts == n.uint64
              check rc.value.nSlotLists == 0
              check rc.value.processed == seq[(NodeTag,NodeTag)].default


proc storagesRunner(
    noisy = true;
    persistent = true;
    sample = storSample;
    knownFailures: seq[(string,seq[(int,HexaryError)])] = @[]) =
  let
    peer = Peer.new
    accountsList = sample.to(seq[UndumpAccounts])
    storagesList = sample.to(seq[UndumpStorages])
    root = accountsList[0].root
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(sample.name, instances=1) else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"
    fileInfo = sample.file.splitPath.tail.replace(".txt.gz","")

  defer:
    if db.persistent:
      if not db.cdb[0].rocksStoreRef.isNil:
        db.cdb[0].rocksStoreRef.store.db.rocksdb_close
      tmpDir.flushDbDir(sample.name)

  suite &"SyncSnap: {fileInfo} accounts storage for {info}":
    let
      dbBase = if persistent: SnapDbRef.init(db.cdb[0])
               else: SnapDbRef.init(newMemoryDB())

    test &"Merging {accountsList.len} accounts for state root ..{root.pp}":
      for w in accountsList:
        let desc = SnapDbAccountsRef.init(dbBase, root, peer)
        check desc.importAccounts(w.base, w.data, persistent).isImportOk

    test &"Merging {storagesList.len} storages lists":
      let
        dbDesc = SnapDbStorageSlotsRef.init(
          dbBase, Hash256().to(NodeKey), Hash256(), peer)
        ignore = knownFailures.toTable
      for n,w in storagesList:
        let
          testId = fileInfo & "#" & $n
          expRc = if ignore.hasKey(testId):
                    Result[void,seq[(int,HexaryError)]].err(ignore[testId])
                  else:
                    OkStoDb
        check dbDesc.importStorageSlots(w.data, persistent).toStoDbRc == expRc

    test &"Inspecting {storagesList.len} imported storages lists sub-tries":
      let ignore = knownFailures.toTable
      for n,w in storagesList:
        let
          testId = fileInfo & "#" & $n
          errInx = if ignore.hasKey(testId): ignore[testId][0][0]
                   else: high(int)
        for m in 0 ..< w.data.storages.len:
          let
            accKey = w.data.storages[m].account.accKey
            root = w.data.storages[m].account.storageRoot
            dbDesc = SnapDbStorageSlotsRef.init(dbBase, accKey, root, peer)
            rc = dbDesc.inspectStorageSlotsTrie(persistent=persistent)
          if m == errInx:
            check rc == Result[TrieNodeStat,HexaryError].err(TrieIsEmpty)
          else:
            check rc.isOk # ok => level > 0 and not stopped


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

  # The `accountsRunner()` tests a snap sync functionality for storing chain
  # chain data directly rather than derive them by executing the EVM. Here,
  # only accounts are considered.
  #
  # The `snap/1` protocol allows to fetch data for a certain account range. The
  # following boundary conditions apply to the received data:
  #
  # * `State root`: All data are relaive to the same state root.
  #
  # * `Accounts`: There is an accounts interval sorted in strictly increasing
  #   order. The accounts are required consecutive, i.e. without holes in
  #   between although this cannot be verified immediately.
  #
  # * `Lower bound`: There is a start value which might be lower than the first
  #   account hash. There must be no other account between this start value and
  #   the first account (not verifyable yet.) For all practicat purposes, this
  #   value is mostly ignored but carried through.
  #
  # * `Proof`: There is a list of hexary nodes which allow to build a partial
  #   Patricia-Merkle trie starting at the state root with all the account
  #   leaves. There are enough nodes that show that there is no account before
  #   the least account (which is currently ignored.)
  #
  # There are test data samples on the sub-directory `test_sync_snap`. These
  # are complete replies for some (admittedly smapp) test requests from a `kiln`
  # session.
  #
  # The `accountsRunner()` does three tests:
  #
  # 1. Run the `importAccounts()` function which is the all-in-one production
  #    function processoing the data described above. The test applies it
  #    sequentially to about 20 data sets.
  #
  # 2. Test individual functional items which are hidden in test 1. while
  #    merging the sample data.
  #    * Load/accumulate `proofs` data from several samples
  #    * Load/accumulate accounts (needs some unique sorting)
  #    * Build/complete hexary trie for accounts
  #    * Save/bulk-store hexary trie on disk. If rocksdb is available, data
  #      are bulk stored via sst.
  #
  # 3. Traverse trie nodes stored earlier. The accounts from test 2 are
  #    re-visted using the account hash as access path.
  #

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
    let knownFailures = @[
      ("storages3__18__25_dump#11", @[( 233, RightBoundaryProofFailed)]),
      ("storages4__26__33_dump#11", @[(1193, RightBoundaryProofFailed)]),
      ("storages5__34__41_dump#10", @[( 508, RootNodeMismatch)]),
      ("storagesB__84__92_dump#6",  @[( 325, RightBoundaryProofFailed)]),
      ("storagesD_102_109_dump#17", @[(1102, RightBoundaryProofFailed)]),
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
