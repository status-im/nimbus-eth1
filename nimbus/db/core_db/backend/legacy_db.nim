# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
  ../../../errors,
  ".."/[base, base/base_desc]

type
  LegacyApiRlpError* = object of CoreDbApiError
    ## For re-routing exceptions in iterator closure

  # -----------

  LegacyDbRef* = ref object of CoreDbRef
    kvt: CoreDxKvtRef    ## Cache, no need to rebuild methods descriptor
    tdb: TrieDatabaseRef ## Copy of descriptor reference captured with closures

  LegacyDbClose* = proc() {.gcsafe, raises: [].}
    ## Custom destructor

  HexaryChildDbRef = ref object
    trie: HexaryTrie     ## needed for descriptor capturing with closures

  RecorderRef = ref object of RootRef
    flags: set[CoreDbCaptFlags]
    parent: TrieDatabaseRef
    logger: LegacyDbRef
    appDb: LegacyDbRef

  LegacyCoreDbVid* = ref object of CoreDbVidRef
    vHash: Hash256       ## Hash key

  LegacyCoreDbError = ref object of CoreDbErrorRef
    ctx: string          ## Context where the exception or error occured
    name: string         ## name of exception
    msg: string          ## Exception info

  # ------------

  LegacyCoreDbBE = ref object of CoreDbBackendRef
    base: LegacyDbRef

  LegacyCoreDbKvtBE = ref object of CoreDbKvtBackendRef
    tdb: TrieDatabaseRef

  LegacyCoreDbMptBE = ref object of CoreDbMptBackendRef
    mpt: HexaryTrie

  LegacyCoreDbAccBE = ref object of CoreDbAccBackendRef
    mpt: HexaryTrie

proc init*(
    db: LegacyDbRef;
    dbType: CoreDbType;
    tdb: TrieDatabaseRef;
    closeDb = LegacyDbClose(nil);
      ): CoreDbRef
      {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers, exception management
# ------------------------------------------------------------------------------

template mapRlpException(db: LegacyDbRef; info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    return err(db.bless(RlpException, LegacyCoreDbError(
      ctx:  info,
      name: $e.name,
      msg:  e.msg)))

template reraiseRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    let msg = info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
    raise (ref LegacyApiRlpError)(msg: msg)

# ------------------------------------------------------------------------------
# Private helpers, other functions
# ------------------------------------------------------------------------------

proc errorPrint(e: CoreDbErrorRef): string =
   if not e.isNil:
     let e = e.LegacyCoreDbError
     result &= "ctx=\"" & $e.ctx & "\""
     if e.name != "":
       result &= ", name=\"" & $e.name & "\""
     if e.msg != "":
       result &= ", msg=\"" & $e.msg & "\""

func lvHash(vid: CoreDbVidRef): Hash256 =
  if not vid.isNil and vid.ready:
    return vid.LegacyCoreDbVid.vHash
  EMPTY_ROOT_HASH

proc toCoreDbAccount(
    data: Blob;
    db: LegacyDbRef;
      ): CoreDbAccount
      {.gcsafe, raises: [RlpError].} =
  let acc = rlp.decode(data, Account)
  CoreDbAccount(
    nonce:      acc.nonce,
    balance:    acc.balance,
    codeHash:   acc.codeHash,
    storageVid: db.bless LegacyCoreDbVid(vHash: acc.storageRoot))

proc toAccount(
    account: CoreDbAccount
      ): Account =
  ## Fast rewrite of `recast()` from base which reures to `vidHashFn()`
  Account(
    nonce:       account.nonce,
    balance:     account.balance,
    codeHash:    account.codeHash,
    storageRoot: account.storageVid.lvHash)

# ------------------------------------------------------------------------------
# Private mixin methods for `trieDB` (backport from capturedb/tracer sources)
# ------------------------------------------------------------------------------

proc get(db: RecorderRef, key: openArray[byte]): Blob =
  ## Mixin for `trieDB()`
  result = db.logger.tdb.get(key)
  if result.len == 0:
    result = db.parent.get(key)
    if result.len != 0:
      db.logger.tdb.put(key, result)

proc put(db: RecorderRef, key, value: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.logger.tdb.put(key, value)
  if PersistPut in db.flags:
    db.parent.put(key, value)

proc contains(db: RecorderRef, key: openArray[byte]): bool =
  ## Mixin for `trieDB()`
  result = db.parent.contains(key)
  doAssert(db.logger.tdb.contains(key) == result)

proc del(db: RecorderRef, key: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.logger.tdb.del(key)
  if PersistDel in db.flags:
    db.parent.del(key)

proc newRecorderRef(
    tdb: TrieDatabaseRef;
    dbType: CoreDbType,
    flags: set[CoreDbCaptFlags];
      ): RecorderRef =
  ## Capture constuctor, uses `mixin` values from above
  result = RecorderRef(
    flags:    flags,
    parent:   tdb,
    logger: LegacyDbRef().init(LegacyDbMemory, newMemoryDB()).LegacyDbRef)
  result.appDb = LegacyDbRef().init(dbType, trieDB result).LegacyDbRef

# ------------------------------------------------------------------------------
# Private database method function tables
# ------------------------------------------------------------------------------

proc kvtMethods(db: LegacyDbRef): CoreDbKvtFns =
  ## Key-value database table handlers
  let tdb = db.tdb
  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      db.bless(LegacyCoreDbKvtBE(tdb: tdb)),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      let data = tdb.get(k)
      if 0 < data.len:
        return ok(data)
      err(db.bless(KvtNotFound, LegacyCoreDbError(ctx: "getFn()"))),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      tdb.del(k)
      ok(),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      tdb.put(k,v)
      ok(),

    hasKeyFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      ok(tdb.contains(k)),

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      ok(),

    pairsIt: iterator(): (Blob, Blob) =
      for k,v in tdb.pairsInMemoryDB:
        yield (k,v))

proc mptMethods(mpt: HexaryChildDbRef; db: LegacyDbRef): CoreDbMptFns =
  ## Hexary trie database handlers
  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      db.bless(LegacyCoreDbMptBE(mpt: mpt.trie)),

    fetchFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      db.mapRlpException("fetchFn()"):
        let data = mpt.trie.get(k)
        if 0 < data.len:
          return ok(data)
      err(db.bless(MptNotFound, LegacyCoreDbError(ctx: "fetchFn()"))),

    deleteFn: proc(k: openArray[byte]): CoreDbRc[void] =
      db.mapRlpException("deleteFn()"):
        mpt.trie.del(k)
      ok(),

    mergeFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      db.mapRlpException("mergeFn()"):
        mpt.trie.put(k,v)
      ok(),

    hasPathFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      db.mapRlpException("hasPathFn()"):
        return ok(mpt.trie.contains(k)),

    rootVidFn: proc(): CoreDbVidRef =
      db.bless(LegacyCoreDbVid(vHash: mpt.trie.rootHash)),

    isPruningFn: proc(): bool =
      mpt.trie.isPruning,

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      ok(),

    pairsIt: iterator: (Blob,Blob) {.gcsafe, raises: [LegacyApiRlpError].} =
      reraiseRlpException("pairsIt()"):
        for k,v in mpt.trie.pairs():
          yield (k,v),

    replicateIt: iterator: (Blob,Blob) {.gcsafe, raises: [LegacyApiRlpError].} =
      reraiseRlpException("replicateIt()"):
        for k,v in mpt.trie.replicate():
          yield (k,v))

proc accMethods(mpt: HexaryChildDbRef; db: LegacyDbRef): CoreDbAccFns =
  ## Hexary trie database handlers
  CoreDbAccFns(
    backendFn: proc(): CoreDbAccBackendRef =
      db.bless(LegacyCoreDbAccBE(mpt: mpt.trie)),

    fetchFn: proc(k: EthAddress): CoreDbRc[CoreDbAccount] =
      db.mapRlpException "fetchFn()":
        let data = mpt.trie.get(k.keccakHash.data)
        if 0 < data.len:
          return ok data.toCoreDbAccount(db)
      err(db.bless(AccNotFound, LegacyCoreDbError(ctx: "fetchFn()"))),

    deleteFn: proc(k: EthAddress): CoreDbRc[void] =
      db.mapRlpException("deleteFn()"):
        mpt.trie.del(k.keccakHash.data)
      ok(),

    mergeFn: proc(k: EthAddress; v: CoreDbAccount): CoreDbRc[void] =
      db.mapRlpException("mergeFn()"):
        mpt.trie.put(k.keccakHash.data, rlp.encode v.toAccount)
      ok(),

    hasPathFn: proc(k: EthAddress): CoreDbRc[bool] =
      db.mapRlpException("hasPath()"):
        return ok(mpt.trie.contains k.keccakHash.data),

    rootVidFn: proc(): CoreDbVidRef =
      db.bless(LegacyCoreDbVid(vHash: mpt.trie.rootHash)),

    isPruningFn: proc(): bool =
      mpt.trie.isPruning,

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      ok())

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

    logDbFn: proc(): CoreDbRc[CoreDbRef] =
      ok(cpt.logger),

    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      cpt.flags)

# ------------------------------------------------------------------------------
# Private base methods (including constructors)
# ------------------------------------------------------------------------------

proc baseMethods(
    db: LegacyDbRef;
    dbType: CoreDbType;
    closeDb: LegacyDbClose;
      ): CoreDbBaseFns =
  let tdb = db.tdb
  CoreDbBaseFns(
    backendFn: proc(): CoreDbBackendRef =
      db.bless(LegacyCoreDbBE(base: db)),

    destroyFn: proc(ignore: bool) =
      if not closeDb.isNil:
        closeDb(),

    vidHashFn: proc(vid: CoreDbVidRef): Result[Hash256,void] =
      ok(vid.lvHash),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    legacySetupFn: proc() =
      db.tdb.put(EMPTY_ROOT_HASH.data, @[0x80u8]),

    getRootFn: proc(root: Hash256; createOk: bool): CoreDbRc[CoreDbVidRef] =
      if root == EMPTY_CODE_HASH:
        return ok(db.bless LegacyCoreDbVid(vHash: EMPTY_CODE_HASH))

      # Due to the way it is used for creating a ne root node, `createOk` must
      # be checked before `contains()` is run. Otherwise it might bail out in
      # the assertion of the above trace/recorder mixin `contains()` function.
      if createOk or tdb.contains(root.data):
        return ok(db.bless LegacyCoreDbVid(vHash: root))

      err(db.bless(RootNotFound, LegacyCoreDbError(ctx: "getRoot()"))),

    newKvtFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[CoreDxKvtRef] =
      ok(db.kvt),

    newMptFn: proc(
        root: CoreDbVidRef,
        prune: bool;
        saveMode: CoreDbSaveFlags;
          ): CoreDbRc[CoreDxMptRef] =
      let mpt = HexaryChildDbRef(trie: initHexaryTrie(tdb, root.lvHash, prune))
      ok(db.bless CoreDxMptRef(methods: mpt.mptMethods db)),

    newAccFn: proc(
        root: CoreDbVidRef,
        prune: bool;
        saveMode: CoreDbSaveFlags;
          ): CoreDbRc[CoreDxAccRef] =
      let mpt = HexaryChildDbRef(trie: initHexaryTrie(tdb, root.lvHash, prune))
      ok(db.bless CoreDxAccRef(methods: mpt.accMethods db)),

    getIdFn: proc(): CoreDbRc[CoreDxTxID] =
      ok(db.bless CoreDxTxID(methods: tdb.getTransactionID.tidMethods(tdb))),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      ok(db.bless CoreDxTxRef(methods: tdb.beginTransaction.txMethods)),

    captureFn: proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] =
      let fns = newRecorderRef(tdb, dbtype, flgs).cptMethods
      ok(db.bless CoreDxCaptRef(methods: fns)))

# ------------------------------------------------------------------------------
# Public constructor helpers
# ------------------------------------------------------------------------------

proc init*(
    db: LegacyDbRef;
    dbType: CoreDbType;
    tdb: TrieDatabaseRef;
    closeDb = LegacyDbClose(nil);
     ): CoreDbRef =
  ## Constructor helper

  # Local extensions
  db.tdb = tdb
  db.kvt = db.bless CoreDxKvtRef(methods: db.kvtMethods())

  # Base descriptor
  db.dbType = dbType
  db.methods = db.baseMethods(dbType, closeDb)
  db.bless

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

func toLegacy*(be: CoreDbAccBackendRef): HexaryTrie =
  if be.parent.isLegacy:
    return be.LegacyCoreDbAccBE.mpt

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
