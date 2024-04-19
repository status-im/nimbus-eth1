# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/tables,
  eth/[common, rlp, trie/db, trie/hexary],
  stew/byteutils,
  results,
  ../../../errors,
  ".."/[base, base/base_desc]

type
  LegacyApiRlpError* = object of CoreDbApiError
    ## For re-routing exceptions in iterator closure

  # -----------

  LegacyDbRef* = ref object of CoreDbRef
    kvt: CoreDxKvtRef       ## Cache, no need to rebuild methods descriptor
    tdb: TrieDatabaseRef    ## Descriptor reference copy captured with closures
    top: LegacyCoreDxTxRef  ## Top transaction (if any)
    ctx: LegacyCoreDbCtxRef ## Cache, there is only one context here
    level: int              ## Debugging

  LegacyDbClose* = proc() {.gcsafe, raises: [].}
    ## Custom destructor

  HexaryChildDbRef = ref object
    trie: HexaryTrie              ## For closure descriptor for capturing
    when CoreDbEnableApiTracking:
      colType: CoreDbColType      ## Current sub-trie
      address: Option[EthAddress] ## For storage tree debugging
      accPath: Blob               ## For storage tree debugging

  LegacyCoreDbCtxRef = ref object of CoreDbCtxRef
    ## Context (there is only one context here)
    base: LegacyDbRef

  LegacyCoreDxTxRef = ref object of CoreDxTxRef
    ltx: DbTransaction            ## Legacy transaction descriptor
    back: LegacyCoreDxTxRef       ## Previous transaction
    level: int                    ## Transaction level when positive

  RecorderRef = ref object of RootRef
    flags: set[CoreDbCaptFlags]
    parent: TrieDatabaseRef
    logger: TableRef[Blob,Blob]
    appDb: LegacyDbRef

  LegacyColRef* = ref object of CoreDbColRef
    root: Hash256                 ## Hash key
    when CoreDbEnableApiTracking:
      colType: CoreDbColType      ## Current sub-trie
      address: Option[EthAddress] ## For storage tree debugging
      accPath: Blob               ## For storage tree debugging

  LegacyCoreDbError = ref object of CoreDbErrorRef
    ctx: string                   ## Exception or error context info
    name: string                  ## name of exception
    msg: string                   ## Exception info

  # ------------

  LegacyCoreDbKvtBE = ref object of CoreDbKvtBackendRef
    tdb: TrieDatabaseRef

  LegacyCoreDbMptBE = ref object of CoreDbMptBackendRef
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
    let msg = info & ", name=" & $e.name & ", msg=\"" & e.msg & "\""
    raise (ref LegacyApiRlpError)(msg: msg)

# ------------------------------------------------------------------------------
# Private helpers, other functions
# ------------------------------------------------------------------------------

func errorPrint(e: CoreDbErrorRef): string =
   if not e.isNil:
     let e = e.LegacyCoreDbError
     result &= "ctx=" & $e.ctx
     if e.name != "":
       result &= ", name=\"" & $e.name & "\""
     if e.msg != "":
       result &= ", msg=\"" & $e.msg & "\""

func colPrint(col: CoreDbColRef): string =
  if not col.isNil:
    if not col.ready:
      result = "$?"
    else:
      var col = LegacyColRef(col)
      when CoreDbEnableApiTracking:
        result = "(" & $col.colType & ","
        if col.address.isSome:
          result &= "@"
          if col.accPath.len == 0:
            result &= "ø"
          else:
            result &= col.accPath.toHex & ","
          result &= "%" & col.address.unsafeGet.toHex & ","
      if col.root != EMPTY_ROOT_HASH:
        result &= "£" & col.root.data.toHex
      else:
        result &= "£ø"
      when CoreDbEnableApiTracking:
        result &= ")"

func txLevel(db: LegacyDbRef): int =
  if not db.top.isNil:
    return db.top.level

func lroot(col: CoreDbColRef): Hash256 =
  if not col.isNil and col.ready:
    return col.LegacyColRef.root
  EMPTY_ROOT_HASH


proc toCoreDbAccount(
    db: LegacyDbRef;
    data: Blob;
    address: EthAddress;
      ): CoreDbAccount
      {.gcsafe, raises: [RlpError].} =
  let acc = rlp.decode(data, Account)
  result = CoreDbAccount(
    address:  address,
    nonce:    acc.nonce,
    balance:  acc.balance,
    codeHash: acc.codeHash)
  if acc.storageRoot != EMPTY_ROOT_HASH:
    result.storage = db.bless LegacyColRef(root: acc.storageRoot)
    when CoreDbEnableApiTracking:
      result.storage.LegacyColRef.colType = CtStorage # redundant, ord() = 0
      result.storage.LegacyColRef.address = some(address)
      result.storage.LegacyColRef.accPath = @(address.keccakHash.data)


proc toAccount(
    acc: CoreDbAccount;
      ): Account =
  ## Fast rewrite of `recast()`
  Account(
    nonce:       acc.nonce,
    balance:     acc.balance,
    codeHash:    acc.codeHash,
    storageRoot: acc.storage.lroot)

# ------------------------------------------------------------------------------
# Private mixin methods for `trieDB` (backport from capturedb/tracer sources)
# ------------------------------------------------------------------------------

proc get(db: RecorderRef, key: openArray[byte]): Blob =
  ## Mixin for `trieDB()`
  result = db.logger.getOrDefault @key
  if result.len == 0:
    result = db.parent.get(key)
    if result.len != 0:
      db.logger[@key] = result

proc put(db: RecorderRef, key, value: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.logger[@key] = @value
  if PersistPut in db.flags:
    db.parent.put(key, value)

proc contains(db: RecorderRef, key: openArray[byte]): bool =
  ## Mixin for `trieDB()`
  if db.logger.hasKey @key:
    return true
  if db.parent.contains key:
    return true

proc del(db: RecorderRef, key: openArray[byte]) =
  ## Mixin for `trieDB()`
  db.logger.del @key
  if PersistDel in db.flags:
    db.parent.del key

proc newRecorderRef(
    db: LegacyDbRef;
    flags: set[CoreDbCaptFlags];
      ): RecorderRef =
  ## Capture constuctor, uses `mixin` values from above
  result = RecorderRef(
    flags:  flags,
    parent: db.tdb,
    logger: newTable[Blob,Blob]())
  let newDb = LegacyDbRef(
    level:          db.level+1,
    trackLegaApi:   db.trackLegaApi,
    trackNewApi:    db.trackNewApi,
    trackLedgerApi: db.trackLedgerApi,
    localDbOnly:    db.localDbOnly,
    profTab:        db.profTab,
    ledgerHook:     db.ledgerHook)
  # Note: the **mixin** magic happens in `trieDB()`
  result.appDb = newDb.init(db.dbType, trieDB result).LegacyDbRef

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

    saveOffSiteFn: proc(): CoreDbRc[void] =
      # Emulate `Kvt` behaviour
      if 0 < db.txLevel():
        const info = "saveOffSiteFn()"
        return err(db.bless(TxPending, LegacyCoreDbError(ctx: info)))
      ok(),

    forgetFn: proc(): CoreDbRc[void] =
      ok())

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

    getColFn: proc(): CoreDbColRef =
      var col = LegacyColRef(root: mpt.trie.rootHash)
      when CoreDbEnableApiTracking:
        col.colType = mpt.colType
        col.address = mpt.address
        col.accPath = mpt.accPath
      db.bless(col),

    isPruningFn: proc(): bool =
      mpt.trie.isPruning)

proc accMethods(mpt: HexaryChildDbRef; db: LegacyDbRef): CoreDbAccFns =
  ## Hexary trie database handlers
  CoreDbAccFns(
    getMptFn: proc(): CoreDbRc[CoreDxMptRef] =
      let xMpt = HexaryChildDbRef(trie: mpt.trie)
      ok(db.bless CoreDxMptRef(methods: xMpt.mptMethods db)),

    fetchFn: proc(k: EthAddress): CoreDbRc[CoreDbAccount] =
      db.mapRlpException "fetchFn()":
        let data = mpt.trie.get(k.keccakHash.data)
        if 0 < data.len:
          return ok db.toCoreDbAccount(data,k)
      err(db.bless(AccNotFound, LegacyCoreDbError(ctx: "fetchFn()"))),

    deleteFn: proc(k: EthAddress): CoreDbRc[void] =
      db.mapRlpException("deleteFn()"):
        mpt.trie.del(k.keccakHash.data)
      ok(),

    stoFlushFn: proc(k: EthAddress): CoreDbRc[void] =
      ok(),

    mergeFn: proc(v: CoreDbAccount): CoreDbRc[void] =
      db.mapRlpException("mergeFn()"):
        mpt.trie.put(v.address.keccakHash.data, rlp.encode v.toAccount)
      ok(),

    hasPathFn: proc(k: EthAddress): CoreDbRc[bool] =
      db.mapRlpException("hasPath()"):
        return ok(mpt.trie.contains k.keccakHash.data),

    getColFn: proc(): CoreDbColRef =
      var col = LegacyColRef(root: mpt.trie.rootHash)
      when CoreDbEnableApiTracking:
        col.colType = mpt.colType
        col.address = mpt.address
        col.accPath = mpt.accPath
      db.bless(col),

    isPruningFn: proc(): bool =
      mpt.trie.isPruning)


proc ctxMethods(ctx: LegacyCoreDbCtxRef): CoreDbCtxFns =
  let
    db = ctx.base
    tdb = db.tdb

  CoreDbCtxFns(
    newColFn: proc(
        colType: CoreDbColType;
        root: Hash256;
        address: Option[EthAddress];
          ): CoreDbRc[CoreDbColRef] =
      var col = LegacyColRef(root: root)
      when CoreDbEnableApiTracking:
        col.colType = colType
        col.address = address
        if address.isSome:
          col.accPath = @(address.unsafeGet.keccakHash.data)
      ok(db.bless col),

    getMptFn: proc(col: CoreDbColRef, prune: bool): CoreDbRc[CoreDxMptRef] =
      var mpt = HexaryChildDbRef(trie: initHexaryTrie(tdb, col.lroot, prune))
      when CoreDbEnableApiTracking:
        if not col.isNil and col.ready:
          let col = col.LegacyColRef
          mpt.colType = col.colType
          mpt.address = col.address
          mpt.accPath = col.accPath
      ok(db.bless CoreDxMptRef(methods: mpt.mptMethods db)),

    getAccFn: proc(col: CoreDbColRef, prune: bool): CoreDbRc[CoreDxAccRef] =
      var mpt = HexaryChildDbRef(trie: initHexaryTrie(tdb, col.lroot, prune))
      when CoreDbEnableApiTracking:
        if not col.isNil and col.ready:
          if col.LegacyColRef.colType != CtAccounts:
            let ctx = LegacyCoreDbError(
              ctx: "newAccFn()",
              msg: "got " & $col.LegacyColRef.colType)
            return err(db.bless(RootUnacceptable, ctx))
          mpt.colType = CtAccounts
      ok(db.bless CoreDxAccRef(methods: mpt.accMethods db)),

    forgetFn: proc() =
      discard)


proc txMethods(tx: CoreDxTxRef): CoreDbTxFns =
  let tx = tx.LegacyCoreDxTxRef

  proc pop(tx: LegacyCoreDxTxRef) =
    if 0 < tx.level:
      tx.parent.LegacyDbRef.top = tx.back
      tx.back = LegacyCoreDxTxRef(nil)
      tx.level = -1

  CoreDbTxFns(
    levelFn: proc(): int =
      tx.level,

    commitFn: proc(applyDeletes: bool): CoreDbRc[void] =
      tx.ltx.commit(applyDeletes)
      tx.pop()
      ok(),

    rollbackFn: proc(): CoreDbRc[void] =
      tx.ltx.rollback()
      tx.pop()
      ok(),

    disposeFn: proc(): CoreDbRc[void] =
      tx.ltx.dispose()
      tx.pop()
      ok(),

    safeDisposeFn: proc(): CoreDbRc[void] =
      tx.ltx.safeDispose()
      tx.pop()
      ok())

proc cptMethods(cpt: RecorderRef; db: LegacyDbRef): CoreDbCaptFns =
  CoreDbCaptFns(
    recorderFn: proc(): CoreDbRef =
      cpt.appDb,

    logDbFn: proc(): TableRef[Blob,Blob] =
      cpt.logger,

    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      cpt.flags,

    forgetFn: proc() =
      discard)

# ------------------------------------------------------------------------------
# Private base methods (including constructors)
# ------------------------------------------------------------------------------

proc baseMethods(
    db: LegacyDbRef;
    dbType: CoreDbType;
    closeDb: LegacyDbClose;
      ): CoreDbBaseFns =
  let db = db
  CoreDbBaseFns(
    levelFn: proc(): int =
      db.txLevel(),

    destroyFn: proc(ignore: bool) =
      if not closeDb.isNil:
        closeDb(),

    colStateFn: proc(col: CoreDbColRef): CoreDbRc[Hash256] =
      ok(col.lroot),

    colPrintFn: proc(col: CoreDbColRef): string =
      col.colPrint(),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    legacySetupFn: proc() =
      db.tdb.put(EMPTY_ROOT_HASH.data, @[0x80u8]),

    newKvtFn: proc(sharedTable = true): CoreDbRc[CoreDxKvtRef] =
      ok(db.kvt),

    newCtxFn: proc(): CoreDbCtxRef =
      db.ctx,

    swapCtxFn: proc(ctx: CoreDbCtxRef): CoreDbCtxRef =
      doAssert CoreDbCtxRef(db.ctx) == ctx
      ctx,

    newCtxFromTxFn: proc(
        root: Hash256;
        colType: CoreDbColType;
          ): CoreDbRc[CoreDbCtxRef] =
      ok(db.ctx),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      db.top = LegacyCoreDxTxRef(
        ltx:   db.tdb.beginTransaction,
        level: (if db.top.isNil: 1 else: db.top.level + 1),
        back:  db.top)
      db.top.methods = db.top.txMethods()
      ok(db.bless db.top),

    newCaptureFn: proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] =
      let fns = db.newRecorderRef(flgs).cptMethods(db)
      ok(db.bless CoreDxCaptRef(methods: fns)),

    persistentFn: proc(): CoreDbRc[void] =
      # Emulate `Aristo` behaviour
      if 0 < db.txLevel():
        const info = "persistentFn()"
        return err(db.bless(TxPending, LegacyCoreDbError(ctx: info)))
      ok())

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

  # Blind context layer
  let ctx = LegacyCoreDbCtxRef(base: db)
  ctx.methods = ctx.ctxMethods
  db.ctx = db.bless ctx

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

func toLegacy*(be: CoreDbKvtBackendRef): TrieDatabaseRef =
  if be.parent.isLegacy:
    return be.LegacyCoreDbKvtBE.tdb

func toLegacy*(be: CoreDbMptBackendRef): HexaryTrie =
  if be.parent.isLegacy:
    return be.LegacyCoreDbMptBE.mpt

# ------------------------------------------------------------------------------
# Public legacy iterators
# ------------------------------------------------------------------------------

iterator legaKvtPairs*(kvt: CoreDxKvtRef): (Blob, Blob) =
  for k,v in kvt.parent.LegacyDbRef.tdb.pairsInMemoryDB:
    yield (k,v)

iterator legaMptPairs*(
    mpt: CoreDxMptRef;
      ): (Blob,Blob)
      {.gcsafe, raises: [LegacyApiRlpError].} =
  reraiseRlpException("legaMptPairs()"):
    for k,v in mpt.methods.backendFn().LegacyCoreDbMptBE.mpt.pairs():
      yield (k,v)

iterator legaReplicate*(
    mpt: CoreDxMptRef;
      ): (Blob,Blob)
      {.gcsafe, raises: [LegacyApiRlpError].} =
  reraiseRlpException("legaReplicate()"):
    for k,v in mpt.methods.backendFn().LegacyCoreDbMptBE.mpt.replicate():
      yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
