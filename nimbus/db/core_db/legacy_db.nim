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
  results,
  ../../errors,
  "."/[base, base/base_desc]

type
  LegacyApiRlpError* = object of CoreDbApiError
    ## For re-routing exceptions in iterator closure

  LegacyDbRef* = ref object of CoreDbRef
    tdb: TrieDatabaseRef # copy of descriptor reference captured with closures

  HexaryTrieRef = ref object
    trie: HexaryTrie     # nedded for decriptor capturing with closures

  RecorderRef = ref object of RootRef
    flags: set[CoreDbCaptFlags]
    parent: TrieDatabaseRef
    recorder: TrieDatabaseRef
    appDb: CoreDbRef

  LegacyCoreDbBE = ref object of CoreDbBackendRef
    base: LegacyDbRef

  LegacyCoreDbKvtBE = ref object of CoreDbKvtBackendRef
    tdb: TrieDatabaseRef

  LegacyCoreDbMptBE = ref object of CoreDbMptBackendRef
    mpt: HexaryTrie

  LegacyCoreDbError = object of CoreDbError
    ctx: string     ## Context where the exception occured
    name: string    ## name of exception
    msg: string     ## Exception info

proc init*(
    db: LegacyDbRef;
    dbType: CoreDbType;
    tdb: TrieDatabaseRef;
      ): CoreDbRef
      {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers, exceprion management
# ------------------------------------------------------------------------------

template mapRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    return err(LegacyCoreDbError(
      ctx: info,
      name: $e.name,
      msg: e.msg))

template reraiseRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    let msg = info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
    raise (ref LegacyApiRlpError)(msg: msg)

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

proc miscMethods(db: LegacyDbRef): CoreDbMiscFns =
  CoreDbMiscFns(
    backendFn: proc(): CoreDbBackendRef =
      LegacyCoreDbBE(base: db),

    legacySetupFn: proc() =
      db.tdb.put(EMPTY_ROOT_HASH.data, @[0x80u8]))

proc kvtMethods(tdb: TrieDatabaseRef): CoreDbKvtFns =
  ## Key-value database table handlers
  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      LegacyCoreDbKvtBE(tdb: tdb),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      ok(tdb.get(k)),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      tdb.del(k)
      ok(),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      tdb.put(k,v)
      ok(),

    containsFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      ok(tdb.contains(k)),

    pairsIt: iterator(): (Blob, Blob) =
      for k,v in tdb.pairsInMemoryDB:
        yield (k,v))

proc mptMethods(mpt: HexaryTrieRef): CoreDbMptFns =
  ## Hexary trie database handlers
  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      LegacyCoreDbMptBE(mpt: mpt.trie),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      mapRlpException("legacy/mpt/get()"):
        return ok(mpt.trie.get(k))
      discard,

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      mapRlpException("legacy/mpt/del()"):
        mpt.trie.del(k)
      ok(),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mapRlpException("legacy/mpt/put()"):
        mpt.trie.put(k,v)
      ok(),

    containsFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      mapRlpException("legacy/mpt/put()"):
        return ok(mpt.trie.contains(k))
      discard,

    rootHashFn: proc(): CoreDbRc[Hash256] =
      ok(mpt.trie.rootHash),

    isPruningFn: proc(): bool =
      mpt.trie.isPruning,

    pairsIt: iterator(): (Blob, Blob) {.gcsafe, raises: [CoreDbApiError].} =
      reraiseRlpException("legacy/mpt/pairs()"):
        for k,v in mpt.trie.pairs():
          yield (k,v)
      discard,

    replicateIt: iterator(): (Blob, Blob) {.gcsafe, raises: [CoreDbApiError].} =
      reraiseRlpException("legacy/mpt/replicate()"):
        for k,v in mpt.trie.replicate():
          yield (k,v)
      discard)

proc txMethods(tx: DbTransaction): CoreDbTxFns =
  CoreDbTxFns(
    commitFn: proc(applyDeletes: bool): CoreDbRc[void] =
      tx.commit(applyDeletes)
      ok(),

    rollbackFn: proc(): CoreDbRc[void] =
      tx.rollback()
      ok(),

    disposeFn: proc(): CoreDbRc[void] =
      tx.dispose()
      ok(),

    safeDisposeFn: proc(): CoreDbRc[void] =
      tx.safeDispose()
      ok())

proc tidMethods(tid: TransactionID; tdb: TrieDatabaseRef): CoreDbTxIdFns =
  CoreDbTxIdFns(
    roWrapperFn: proc(action: CoreDbTxIdActionFn): CoreDbRc[void] =
      tdb.shortTimeReadOnly(tid, action())
      ok())

proc cptMethods(cpt: RecorderRef): CoreDbCaptFns =
  CoreDbCaptFns(
    recorderFn: proc(): CoreDbRc[CoreDbRef] =
      ok(cpt.appDb),

    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      cpt.flags)

# ------------------------------------------------------------------------------
# Private constructor functions table
# ------------------------------------------------------------------------------

proc constructors(
    tdb: TrieDatabaseRef;
    parent: CoreDbRef;
      ): CoreDbConstructorFns =
  CoreDbConstructorFns(
    mptFn: proc(root: Hash256): CoreDbRc[CoreDxMptRef] =
      let mpt = HexaryTrieRef(trie: initHexaryTrie(tdb, root, false))
      ok(newCoreDbMptRef(parent, mpt.mptMethods)),

    legacyMptFn: proc(root: Hash256; prune: bool): CoreDbRc[CoreDxMptRef] =
      let mpt = HexaryTrieRef(trie: initHexaryTrie(tdb, root, prune))
      ok(newCoreDbMptRef(parent, mpt.mptMethods)),

    getIdFn: proc(): CoreDbRc[CoreDxTxID] =
      ok(newCoreDbTxID(parent, tdb.getTransactionID.tidMethods tdb)),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      ok(newCoreDbTxRef(parent, tdb.beginTransaction.txMethods)),

    captureFn: proc(flags: set[CoreDbCaptFlags] = {}): CoreDbRc[CoreDxCaptRef] =
      ok(newCoreDbCaptRef(parent, newRecorderRef(tdb, flags).cptMethods)))

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
    dbMethods =  db.miscMethods,
    kvtMethods = tdb.kvtMethods,
    newSubMod =  tdb.constructors db)
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

func isLegacy*(be: CoreDbRef): bool =
  be.dbType in {LegacyDbMemory, LegacyDbPersistent}

#func toLegacy*(be: CoreDbBackendRef): LegacyDbRef =
#  if be.parent.isLegacy:
#    return be.LegacyCoreDbBE.base

func toLegacy*(be: CoreDbKvtBackendRef): TrieDatabaseRef =
  if be.parent.isLegacy:
    return be.LegacyCoreDbKvtBE.tdb

func toLegacy*(be: CoreDbMptBackendRef): HexaryTrie =
  if be.parent.isLegacy:
    return be.LegacyCoreDbMptBE.mpt
 
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
