# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/options,
  chronicles,
  eth/[common, rlp, trie/db, trie/hexary],
  results,
  ../../constants,
  ../select_backend,
  ./base

logScope:
  topics = "core_db-legacy"

type
  LegacyCoreDbRef* = ref object of CoreDbRef
    backend: ChainDB

  LegacyCoreDbKvtRef* = ref object of CoreDbKvtRef
    ## Holds single database
    db*: TrieDatabaseRef

  LegacyCoreDbMptRef* = ref object of CoreDbMptRef
    mpt: HexaryTrie

  LegacyCoreDbPhkRef* = ref object of CoreDbPhkRef
    phk: SecureHexaryTrie


  LegacyCoreDbTxRef* = ref object of CoreDbTxRef
    tx: DbTransaction

  LegacyCoreDbTxID* = ref object of CoreDbTxID
    tid: TransactionID


  LegacyCoreDbCaptRef* = ref object of CoreDbCaptRef
    recorder: TrieDatabaseRef
    appDb: LegacyCoreDbRef

# ------------------------------------------------------------------------------
# Public constructor and low level data retrieval, storage & transation frame
# ------------------------------------------------------------------------------

proc newLegacyCoreDbRef*(db: TrieDatabaseRef): LegacyCoreDbRef =
  result = LegacyCoreDbRef()
  result.init(LegacyDbPersistent, LegacyCoreDbKvtRef(db: db))

proc newLegacyPersistentCoreDbRef*(
    path: string;
      ): LegacyCoreDbRef =
  # Kludge: Compiler bails out on `results.tryGet()` with
  # ::
  #   fatal.nim(54)            sysFatal
  #   Error: unhandled exception: types.nim(1251, 10) \
  #     `b.kind in {tyObject} + skipPtrs`  [AssertionDefect]
  #
  # when running `select_backend.newChainDB(path)`. The culprit seems to be
  # the `ResultError` exception (or any other `CatchableError`).
  #
  doAssert dbBackend == rocksdb
  let rc = RocksStoreRef.init(path, "nimbus")
  doAssert(rc.isOk, "Cannot start RocksDB: " & rc.error)
  doAssert(not rc.value.isNil, "Starting RocksDB returned nil")

  let
    rdb = rc.value
    backend = ChainDB(kv: rdb.kvStore, rdb: rdb)

  result = LegacyCoreDbRef(backend: backend)
  result.init(LegacyDbPersistent, LegacyCoreDbKvtRef(db: backend.trieDB))

proc newLegacyMemoryCoreDbRef*(): LegacyCoreDbRef =
  result = LegacyCoreDbRef()
  result.init(LegacyDbMemory, LegacyCoreDbKvtRef(db:  newMemoryDB()))

# ------------------------------------------------------------------------------
# Public legacy helpers
# ------------------------------------------------------------------------------

method compensateLegacySetup*(db: LegacyCoreDbRef) =
  db.kvt.LegacyCoreDbKvtRef.db.put(EMPTY_ROOT_HASH.data, @[0x80u8])

proc toLegacyTrieRef*(
    db: CoreDbRef;
      ): TrieDatabaseRef
      {.gcsafe, deprecated: "Will go away some time in future".} =
  db.kvt.LegacyCoreDbKvtRef.db

proc toLegacyBackend*(
    db: CoreDbRef;
      ): ChainDB
      {.gcsafe, deprecated: "Will go away some time in future".} =
  db.LegacyCoreDbRef.backend

# ------------------------------------------------------------------------------
# Public tracer methods (backport from capturedb/tracer sources)
# ------------------------------------------------------------------------------

proc get(db: LegacyCoreDbCaptRef, key: openArray[byte]): Blob =
  ## Mixin for `trieDB()`
  result = db.recorder.get(key)
  if result.len != 0: return
  result = db.parent.kvt.LegacyCoreDbKvtRef.db.get(key)
  if result.len != 0:
    db.recorder.put(key, result)

proc put(db: LegacyCoreDbCaptRef, key, value: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.recorder.put(key, value)
  if PersistPut in db.flags:
    db.parent.kvt.LegacyCoreDbKvtRef.db.put(key, value)

proc contains(db: LegacyCoreDbCaptRef, key: openArray[byte]): bool =
  ## Mixin for `trieDB()`
  result = db.parent.kvt.LegacyCoreDbKvtRef.db.contains(key)
  doAssert(db.recorder.contains(key) == result)

proc del(db: LegacyCoreDbCaptRef, key: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.recorder.del(key)
  if PersistDel in db.flags:
    db.parent.kvt.LegacyCoreDbKvtRef.db.del(key)

method newCoreDbCaptRef*(
    db: LegacyCoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbCaptRef =
  var captDB = LegacyCoreDbCaptRef(recorder: newMemoryDB())
  captDB.init(db, flags)
  captDB.appDb = LegacyCoreDbRef()
  captDB.appDb.init(LegacyDbPersistent, LegacyCoreDbKvtRef(db: trieDB captDB))
  captDB

method recorder*(
    db: LegacyCoreDbCaptRef;
      ): CoreDbRef =
  db.appDb

iterator pairs*(
    db: LegacyCoreDbCaptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  for k,v in db.recorder.pairsInMemoryDB:
    yield (k,v)

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

method get*(
    db: LegacyCoreDbKvtRef;
    key: openArray[byte];
      ): Blob =
  db.db.get key

method maybeGet*(
    db: LegacyCoreDbKvtRef;
    key: openArray[byte];
      ): Option[Blob] =
  db.db.maybeGet key

method del*(
    db: LegacyCoreDbKvtRef;
    key: openArray[byte];
      ) =
  db.db.del key

method put*(
    db: LegacyCoreDbKvtRef;
    key: openArray[byte];
    value: openArray[byte];
      ) =
  db.db.put(key, value)

method contains*(
    db: LegacyCoreDbKvtRef;
    key: openArray[byte];
      ): bool =
  db.db.contains key

# ------------------------------------------------------------------------------
# Public hexary trie methods
# ------------------------------------------------------------------------------

method mpt*(
    db: LegacyCoreDbRef;
    root: Hash256;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db, root, isPruning=false))
  result.init db

method mpt*(
    db: LegacyCoreDbRef;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db, isPruning=false))
  result.init db

method isPruning*(
    db: LegacyCoreDbMptRef;
      ): bool =
  db.mpt.isPruning

# ------

method mptPrune*(
    db: LegacyCoreDbRef;
    root: Hash256;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db, root))
  result.init db

method mptPrune*(
    db: LegacyCoreDbRef;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db))
  result.init db

method mptPrune*(
    db: LegacyCoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db, root, isPruning=prune))
  result.init db

method mptPrune*(
    db: LegacyCoreDbRef;
    prune: bool;
      ): CoreDbMptRef =
  result = LegacyCoreDbMptRef(
    mpt: initHexaryTrie(db.kvt.LegacyCoreDbKvtRef.db, isPruning=prune))
  result.init db

# ------

method get*(
    db: LegacyCoreDbMptRef;
    key: openArray[byte];
      ): Blob
      {.gcsafe, raises: [RlpError].} =
  db.mpt.get key

method maybeGet*(
    db: LegacyCoreDbMptRef;
    key: openArray[byte];
      ): Option[Blob]
      {.gcsafe, raises: [RlpError].} =
  db.mpt.maybeGet key

method del*(
    db: LegacyCoreDbMptRef;
    key: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  db.mpt.del key

method put*(
    db: LegacyCoreDbMptRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  db.mpt.put(key, value)

method contains*(
    db: LegacyCoreDbMptRef;
    key: openArray[byte];
      ): bool
      {.gcsafe, raises: [RlpError].} =
  db.mpt.contains key

method rootHash*(
    db: LegacyCoreDbMptRef;
      ): Hash256 =
  db.mpt.rootHash

iterator pairs*(
    db: LegacyCoreDbMptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  for k,v in db.mpt:
    yield (k,v)

# ------------------------------------------------------------------------------
# Public pre-kashed key hexary trie methods
# ------------------------------------------------------------------------------

method phk*(
    db: LegacyCoreDbRef;
    root: Hash256;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db, root, isPruning=false))
  result.init db

method phk*(
    db: LegacyCoreDbRef;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db, isPruning=false))
  result.init db

method isPruning*(
    db: LegacyCoreDbPhkRef;
      ): bool =
  db.phk.isPruning

# ------

method phkPrune*(
    db: LegacyCoreDbRef;
    root: Hash256;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db, root))
  result.init db

method phkPrune*(
    db: LegacyCoreDbRef;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db))
  result.init db

method phkPrune*(
    db: LegacyCoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db, root, isPruning=prune))
  result.init db

method phkPrune*(
    db: LegacyCoreDbRef;
    prune: bool;
      ): CoreDbPhkRef =
  result = LegacyCoreDbPhkRef(
    phk: initSecureHexaryTrie(
      db.kvt.LegacyCoreDbKvtRef.db, isPruning=prune))
  result.init db

# ------

method get*(
    db: LegacyCoreDbPhkRef;
    key: openArray[byte];
      ): Blob
      {.gcsafe, raises: [RlpError].} =
  db.phk.get key

method maybeGet*(
    db: LegacyCoreDbPhkRef;
    key: openArray[byte];
      ): Option[Blob]
      {.gcsafe, raises: [RlpError].} =
  db.phk.maybeGet key

method del*(
    db: LegacyCoreDbPhkRef;
    key: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  db.phk.del key

method put*(
    db: LegacyCoreDbPhkRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  db.phk.put(key, value)

method contains*(
    db: LegacyCoreDbPhkRef;
    key: openArray[byte];
      ): bool
      {.gcsafe, raises: [RlpError].} =
  db.phk.contains key

method rootHash*(
    db: LegacyCoreDbPhkRef;
      ): Hash256 =
  db.phk.rootHash

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

method getTransactionID*(db: LegacyCoreDbRef): CoreDbTxID =
  LegacyCoreDbTxID(tid: db.kvt.LegacyCoreDbKvtRef.db.getTransactionID)

method setTransactionID*(db: LegacyCoreDbRef; id: CoreDbTxID) =
  db.kvt.LegacyCoreDbKvtRef.db.setTransactionID LegacyCoreDbTxID(id).tid

method beginTransaction*(db: LegacyCoreDbRef): CoreDbTxRef =
  result = LegacyCoreDbTxRef(
    tx: db.kvt.LegacyCoreDbKvtRef.db.beginTransaction())
  result.init db

method commit*(t: LegacyCoreDbTxRef, applyDeletes = true) =
  t.tx.commit applyDeletes

method rollback*(t: LegacyCoreDbTxRef) =
  t.tx.rollback()

method dispose*(t: LegacyCoreDbTxRef) =
  t.tx.dispose()

method safeDispose*(t: LegacyCoreDbTxRef) =
  t.tx.safeDispose()

method shortTimeReadOnly*(
    db: LegacyCoreDbRef;
    id: CoreDbTxID;
    action: proc() {.gcsafe, raises: [CatchableError].};
      ) {.gcsafe, raises: [CatchableError].} =
  db.kvt.LegacyCoreDbKvtRef.db.shortTimeReadOnly LegacyCoreDbTxID(id).tid:
    action()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
