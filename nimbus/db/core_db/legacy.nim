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
  eth/[common, rlp, trie/db, trie/hexary],
  ./base

type
  LegacyDbRef* = ref object of CoreDbRef
    tdb: TrieDatabaseRef # copy of descriptor reference captured with closures

  HexaryTrieRef = ref object
    trie: HexaryTrie     # nedded for decriptor capturing with closures

  RecorderRef = ref object of RootRef
    flags: set[CoreDbCaptFlags]
    parent: TrieDatabaseRef
    recorder: TrieDatabaseRef
    appDb: CoreDbRef

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   rlpRaise, gcsafe, raises: [RlpError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

proc init*(
    db: LegacyDbRef;
    dbType: CoreDbType;
    tdb: TrieDatabaseRef;
      ): CoreDbRef
      {.noRaise.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template ifLegacyOk(db: CoreDbRef; body: untyped) =
  case db.dbType:
  of LegacyDbMemory, LegacyDbPersistent:
    body
  else:
    discard

# ------------------------------------------------------------------------------
# Private mixin methods for `trieDB` (backport from capturedb/tracer sources)
# ------------------------------------------------------------------------------

proc get(db: RecorderRef, key: openArray[byte]): Blob =
  ## Mixin for `trieDB()`
  result = db.recorder.get(key)
  if result.len == 0:
    result = db.parent.get(key)
    if result.len != 0:
      db.recorder.put(key, result)

proc put(db: RecorderRef, key, value: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.recorder.put(key, value)
  if PersistPut in db.flags:
    db.parent.put(key, value)

proc contains(db: RecorderRef, key: openArray[byte]): bool =
  ## Mixin for `trieDB()`
  result = db.parent.contains(key)
  doAssert(db.recorder.contains(key) == result)

proc del(db: RecorderRef, key: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.recorder.del(key)
  if PersistDel in db.flags:
    db.parent.del(key)

proc newRecorderRef(
    tdb: TrieDatabaseRef;
    flags: set[CoreDbCaptFlags] = {};
      ): RecorderRef =
  ## Capture constuctor, uses `mixin` values from above
  result = RecorderRef(
    flags:    flags,
    parent:   tdb,
    recorder: newMemoryDB())
  result.appDb = LegacyDbRef().init(LegacyDbPersistent, trieDB result)

# ------------------------------------------------------------------------------
# Private database method function tables
# ------------------------------------------------------------------------------

proc miscMethods(tdb: TrieDatabaseRef): CoreDbMiscFns =
  CoreDbMiscFns(
    legacySetupFn: proc() =
      tdb.put(EMPTY_ROOT_HASH.data, @[0x80u8]))

proc kvtMethods(tdb: TrieDatabaseRef): CoreDbKvtFns =
  ## Key-value database table handlers
  CoreDbKvtFns(
    getFn:      proc(k: openArray[byte]): Blob =               tdb.get(k),
    maybeGetFn: proc(k: openArray[byte]): Option[Blob] =       tdb.maybeGet(k),
    delFn:      proc(k: openArray[byte]) =                     tdb.del(k),
    putFn:      proc(k: openArray[byte]; v: openArray[byte]) = tdb.put(k,v),
    containsFn: proc(k: openArray[byte]): bool =               tdb.contains(k),
    pairsIt:    iterator(): (Blob, Blob) {.noRaise.} =
      for k,v in tdb.pairsInMemoryDB:
        yield (k,v))

proc mptMethods(mpt: HexaryTrieRef): CoreDbMptFns =
  ## Hexary trie database handlers
  CoreDbMptFns(
    getFn: proc(k: openArray[byte]): Blob {.rlpRaise.} =
      mpt.trie.get(k),

    maybeGetFn: proc(k: openArray[byte]): Option[Blob] {.rlpRaise.} =
      mpt.trie.maybeGet(k),

    delFn: proc(k: openArray[byte]) {.rlpRaise.} =
      mpt.trie.del(k),

    putFn: proc(k: openArray[byte]; v: openArray[byte]) {.rlpRaise.} =
      mpt.trie.put(k,v),

    containsFn: proc(k: openArray[byte]): bool {.rlpRaise.} =
      mpt.trie.contains(k),

    rootHashFn: proc(): Hash256 =
      mpt.trie.rootHash,

    isPruningFn: proc(): bool =
      mpt.trie.isPruning,

    pairsIt: iterator(): (Blob, Blob) {.rlpRaise.} =
      for k,v in mpt.trie.pairs():
        yield (k,v),

    replicateIt: iterator(): (Blob, Blob) {.rlpRaise.} =
      for k,v in mpt.trie.replicate():
        yield (k,v))

proc txMethods(tx: DbTransaction): CoreDbTxFns =
  CoreDbTxFns(
    commitFn:      proc(applyDeletes: bool) = tx.commit(applyDeletes),
    rollbackFn:    proc() =                   tx.rollback(),
    disposeFn:     proc() =                   tx.dispose(),
    safeDisposeFn: proc() =                   tx.safeDispose())

proc tidMethods(tid: TransactionID; tdb: TrieDatabaseRef): CoreDbTxIdFns =
  CoreDbTxIdFns(
    setIdFn: proc() =
      tdb.setTransactionID(tid),

    roWrapperFn: proc(action: CoreDbTxIdActionFn) {.catchRaise.} =
      tdb.shortTimeReadOnly(tid, action()))

proc cptMethods(cpt: RecorderRef): CoreDbCaptFns =
  CoreDbCaptFns(
    recorderFn: proc(): CoreDbRef =
      cpt.appDb,

    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      cpt.flags)

# ------------------------------------------------------------------------------
# Private constructor functions table
# ------------------------------------------------------------------------------

proc constructors(tdb: TrieDatabaseRef, parent: CoreDbRef): CoreDbConstructors =
  CoreDbConstructors(
    mptFn: proc(root: Hash256): CoreDbMptRef =
      let mpt = HexaryTrieRef(trie: initHexaryTrie(tdb, root, false))
      newCoreDbMptRef(parent, mpt.mptMethods),

    legacyMptFn: proc(root: Hash256; prune: bool): CoreDbMptRef =
      let mpt = HexaryTrieRef(trie: initHexaryTrie(tdb, root, prune))
      newCoreDbMptRef(parent, mpt.mptMethods),

    getIdFn: proc(): CoreDbTxID =
      newCoreDbTxID(parent, tdb.getTransactionID.tidMethods tdb),

    beginFn: proc(): CoreDbTxRef =
      newCoreDbTxRef(parent, tdb.beginTransaction.txMethods),

    captureFn: proc(flags: set[CoreDbCaptFlags] = {}): CoreDbCaptRef =
      newCoreDbCaptRef(parent, newRecorderRef(tdb, flags).cptMethods))

# ------------------------------------------------------------------------------
# Public constructor helpers
# ------------------------------------------------------------------------------

proc init*(
    db: LegacyDbRef;
    dbType: CoreDbType;
    tdb: TrieDatabaseRef;
     ): CoreDbRef =
  db.tdb = tdb
  db.init(
    dbType =     dbType,
    dbMethods =  tdb.miscMethods,
    kvtMethods = tdb.kvtMethods,
    new =        tdb.constructors db)
  db

# ------------------------------------------------------------------------------
# Public constructor and low level data retrieval, storage & transation frame
# ------------------------------------------------------------------------------

proc newLegacyPersistentCoreDbRef*(db: TrieDatabaseRef): CoreDbRef =
  LegacyDbRef().init(LegacyDbPersistent, db)

proc newLegacyMemoryCoreDbRef*(): CoreDbRef =
  LegacyDbRef().init(LegacyDbMemory, newMemoryDB())

# ------------------------------------------------------------------------------
# Public legacy helpers
# ------------------------------------------------------------------------------

proc toLegacyTrieRef*(db: CoreDbRef): TrieDatabaseRef =
  db.ifLegacyOk:
    return db.LegacyDbRef.tdb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
