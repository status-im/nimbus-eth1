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
  eth/common,
  results,
  ../../../errors,
  "../.."/[aristo, aristo/aristo_init/memory_only, kvt],
  ".."/[base, base/base_desc]

export
  memory_only

type
  AristoApiRlpError* = object of CoreDbApiError
    ## For re-routing exceptions in iterator closure

  AristoCoreDbRef* = ref object of CoreDbRef
    ## Main descriptor
    adb: AristoDbRef
    kdb: KvtDbRef

  AristoCoreDbError = ref object of CoreDbErrorRef
    ## Error return code
    ctx: string     ## Context where the exception or error occured
    case isAristo: bool
    of true:
      aVid: VertexID
      aErr: AristoError
    else:
      kErr: KvtError

  # -----------

  AristoChildDbRef = ref AristoChildDbObj
  AristoChildDbObj = object
    ## Sub-handle for triggering destructor when it goes out of scope
    root: VertexID            ## State root
    prune: bool               ## Currently unused
    mpt: AristoDbRef          ## Descriptor

  AristoCoreDbVid* = ref object of CoreDbVidRef
    ## Vertex ID wrapper, optinally with *MPT* context
    ctx: AristoDbRef          ## Optional *MPT* context, might be `nil`
    aVid: VertexID            ## Refers to root vertex
    createOk: bool            ## Create new root vertex when appropriate
    expHash: Hash256          ## Deferred validation

  # ------------

  AristoCoreDbBE = ref object of CoreDbBackendRef

  AristoCoreDbKvtBE = ref object of CoreDbKvtBackendRef
    kdb: KvtDbRef

  AristoCoreDbMptBE = ref object of CoreDbMptBackendRef
    adb: AristoDbRef

  AristoCoreDbAccBE = ref object of CoreDbAccBackendRef
    adb: AristoDbRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc errorPrint(e: CoreDbErrorRef): string =
  if not e.isNil:
    let e = e.AristoCoreDbError
    result = if e.isAristo: "Aristo: " else: " Kvt: "
    result &= "ctx=\"" & $e.ctx & "\"" & " , "
    if e.isAristo:
      if e.aVid.isValid:
        result &= "vid=\"" & $e.aVid & "\"" & " , "
      result &= "error=\"" & $e.aErr & "\""
    else:
      result &= "error=\"" & $e.kErr & "\""

func to(vid: CoreDbVidRef; T: type VertexID): T =
  if not vid.isNil and vid.ready:
    return vid.AristoCoreDbVid.aVid

func createOk(vid: CoreDbVidRef): bool =
  if not vid.isNil and vid.ready:
    return vid.AristoCoreDbVid.createOk

func toCoreDbAccount(
    db: AristoCoreDbRef;
    acc: AristoAccount;
    mpt: AristoDbRef;
      ): CoreDbAccount =
  CoreDbAccount(
    nonce:      acc.nonce,
    balance:    acc.balance,
    codeHash:   acc.codeHash,
    storageVid: db.bless AristoCoreDbVid(ctx: mpt, aVid: acc.storageID))

func toPayloadRef(acc: CoreDbAccount): PayloadRef =
  PayloadRef(
    pType:       AccountData,
    account: AristoAccount(
      nonce:     acc.nonce,
      balance:   acc.balance,
      storageID: acc.storageVid.to(VertexID),
      codeHash:  acc.codeHash))

# --------------

template valueOrApiError[U,V](rc: Result[U,V]; info: static[string]): U =
  rc.valueOr: raise (ref AristoApiRlpError)(msg: info)

# --------------

func toCoreDbRc[T](
    rc: Result[T,KvtError];
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err(db.bless AristoCoreDbError(
    ctx:      info,
    isAristo: false,
    kErr:     rc.error))

# --------------

func toCoreDbError(
    e: (VertexID,AristoError);
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbErrorRef =
  db.bless AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aVid:     e[0],
    aErr:     e[1])

func toCoreDbRc[T](
    rc: Result[T,(VertexID,AristoError)];
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err(rc.error.toCoreDbError(db, info))

func toCoreDbRc[T](
    rc: Result[T,AristoError];
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err((VertexID(0),rc.error).toCoreDbError(db, info))

func notImplemented[T](
    _: typedesc[T];
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbRc[T] {.gcsafe.} =
  ## Applies only to `Aristo` methods
  err((VertexID(0),aristo.NotImplemented).toCoreDbError(db, info))

# ------------------------------------------------------------------------------
# Private database method function tables
# ------------------------------------------------------------------------------

proc kvtMethods[T](db: AristoCoreDbRef; _: typedesc[T]): CoreDbKvtFns =
  ## Key-value database table handlers
  let kdb = db.kdb

  CoreDbKvtFns(
    backendFn: proc(): CoreDbKvtBackendRef =
      db.bless(AristoCoreDbKvtBE(kdb: kdb)),

    getFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      kdb.get(k).toCoreDbRc(db, "get()"),

    delFn: proc(k: openArray[byte]): CoreDbRc[void] =
      kdb.del(k).toCoreDbRc(db, "del()"),

    putFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      discard kdb.put(k,v).toCoreDbRc(db, "put()"),

    containsFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      discard kdb.contains(k).toCoreDbRc(db, "contains()"),

    pairsIt: iterator(): (Blob, Blob) =
      for k,v in T.walkPairs kdb:
        yield (k,v))

proc mptMethods(
    db: AristoCoreDbRef;
    cMpt: AristoChildDbRef;
    T: typedesc;
      ): CoreDbMptFns =
  ## Hexary trie database handlers
  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      AristoCoreDbMptBE(adb: cMpt.mpt),

    fetchFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      let pyl = ? cMpt.mpt.fetchPayload(cMpt.root, k).toCoreDbRc(db, "get()")
      cMpt.mpt.serialise(pyl).toCoreDbRc(db, "get()"),

    deleteFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cMpt.mpt.delete(cMpt.root, k).toCoreDbRc(db, "del()"),

    mergeFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      discard cMpt.mpt.merge(cMpt.root, k, v).toCoreDbRc(db, "put()")
      ok(),

    containsFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cMpt.mpt.contains(cMpt.root, k).toCoreDbRc(db, "contains()"),

    rootVidFn: proc(): CoreDbVidRef =
      var w = AristoCoreDbVid(ctx: cMpt.mpt, aVid: cMpt.root)
      db.bless(w),

    isPruningFn: proc(): bool =
      cMpt.prune,

    pairsIt: iterator: (Blob,Blob) =
      for (k,v) in cMpt.mpt.right LeafTie(root: cMpt.root):
        yield (k.path.to(Blob), cMpt.mpt.serialise(v).valueOr(EmptyBlob)),

    replicateIt: iterator: (Blob,Blob) {.gcsafe, raises: [AristoApiRlpError].} =
      let p = cMpt.mpt.forkTop.valueOrApiError("mpt/forkTop() for replicate()")
      defer: discard p.forget()
      for (vid,key,vtx,node) in T.replicate(p):
        yield (key.to(Blob), node.encode))

proc accMethods(
    db: AristoCoreDbRef;
    cMpt: AristoChildDbRef;
    T: typedesc;
      ): CoreDbAccFns =
  ## Hexary trie database handlers
  CoreDbAccFns(
    backendFn: proc(): CoreDbAccBackendRef =
      db.bless(AristoCoreDbAccBE(adb: cMpt.mpt)),

    fetchFn: proc(address: EthAddress): CoreDbRc[CoreDbAccount] =
      let
        info = "getAccount()"
        key = address.keccakHash.data
        pyl = ? cMpt.mpt.fetchPayload(VertexID(1), key).toCoreDbRc(db, info)
      if pyl.pType != AccountData:
        return err((pyl.account.storageID, aristo.PayloadTypeUnsupported)
                       .toCoreDbError(db, info & "/" & $pyl.pType))
      ok(db.toCoreDbAccount(pyl.account, cMpt.mpt)),

    deleteFn: proc(address: EthAddress): CoreDbRc[void] =
      let key = address.keccakHash.data
      cMpt.mpt.delete(cMpt.root, key).toCoreDbRc(db, "del()"),

    mergeFn: proc(address: EthAddress; v: CoreDbAccount): CoreDbRc[void] =
      let key = address.keccakHash.data
      discard cMpt.mpt.merge(
        VertexID(1), key, v.toPayloadRef()).toCoreDbRc(db, "putAccount()")
      ok(),

    containsFn: proc(address: EthAddress): CoreDbRc[bool] =
      let key = address.keccakHash.data
      cMpt.mpt.contains(cMpt.root, key).toCoreDbRc(db, "contains()"),

    rootVidFn: proc(): CoreDbVidRef =
      db.bless(AristoCoreDbVid(ctx: cMpt.mpt, aVid: cMpt.root)),

    isPruningFn: proc(): bool =
      cMpt.prune)

proc `=destroy`(cMpt: var AristoChildDbObj) =
  ## Hexary trie dexctructor to be called automagically when the argument
  ## wrappert gets out of scope
  discard cMpt.mpt.forget()


proc txMethods(
    db: AristoCoreDbRef;
    aTx: AristoTxRef;
    kTx: KvtTxRef;
     ): CoreDbTxFns =
  proc doDispose(): CoreDbRc[void] =
    if aTx.isTop: discard aTx.rollback.toCoreDbRc(db, "dispose()")
    if kTx.isTop: discard kTx.rollback.toCoreDbRc(db, "dispose()")
    ok()

  CoreDbTxFns(
    commitFn: proc(ignore: bool): CoreDbRc[void] =
      discard aTx.commit.toCoreDbRc(db, "commit()")
      discard kTx.commit.toCoreDbRc(db, "commit()"),

    rollbackFn: proc(): CoreDbRc[void] =
      discard aTx.rollback.toCoreDbRc(db, "rollback()")
      discard kTx.rollback.toCoreDbRc(db, "rollback()"),

    disposeFn: proc(): CoreDbRc[void] =
      doDispose(),

    safeDisposeFn: proc(): CoreDbRc[void] =
      doDispose())

proc tidMethods(
    db: AristoCoreDbRef;
    aTx: AristoTxRef;
    kTx: KvtTxRef;
      ): CoreDbTxIdFns =
  CoreDbTxIdFns(
    roWrapperFn: proc(action: CoreDbTxIdActionFn): CoreDbRc[void] =
      var rc = Result[void,KvtError].ok()

      proc kAction(kvt: KvtDbRef) =
        let save = db.kdb
        db.kdb = kvt
        action()
        db.kdb = save

      proc aAction(adb: AristoDbRef) =
        let save = db.adb
        db.adb = adb
        rc = kTx.exec(kAction)
        db.adb = save

      discard aTx.exec(aAction).toCoreDbRc(db, "exec()")
      rc.toCoreDbRc(db, "exec()"))

proc cptMethods(): CoreDbCaptFns =
  CoreDbCaptFns(
    recorderFn: proc(): CoreDbRc[CoreDbRef] =
      raiseAssert("recorderFn() unsupported by Aristo"),
    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      raiseAssert("recorderFn() unsupported by Aristo"))

# ------------------------------------------------------------------------------
# Private base methods (including constructors)
# ------------------------------------------------------------------------------

proc baseMethods(
    db: AristoCoreDbRef;
    T:  typedesc;
      ): CoreDbBaseFns =
  CoreDbBaseFns(
    backendFn: proc(): CoreDbBackendRef =
      db.bless(AristoCoreDbBE()),

    destroyFn: proc(flush: bool) =
      db.adb.finish flush
      db.kdb.finish(flush),

    vidHashFn: proc(vid: CoreDbVidRef): Result[Hash256,void] =
      if not vid.isNil and vid.ready:
        let vid = vid.AristoCoreDbVid
        if vid.aVid.isValid:
          let rc = (if vid.ctx.isNil: db.adb else: vid.ctx).getKeyRc vid.aVid
          if rc.isOk:
            return ok rc.value.to(Hash256)
          doAssert rc.error == GetKeyNotFound
          return err()
      ok(EMPTY_ROOT_HASH),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    legacySetupFn: proc() =
      discard,

    getRootFn: proc(root: Hash256; createOk: bool): CoreDbRc[CoreDbVidRef] =
      if root == VOID_CODE_HASH:
        return ok(db.bless AristoCoreDbVid())
      # Check whether hash is available as state root on main trie
      block:
        let rc = db.adb.getKeyRc VertexID(1)
        if rc.isErr:
          doAssert rc.error == GetKeyNotFound
        elif rc.value == root.to(HashKey):
          return ok(db.bless AristoCoreDbVid(aVid: VertexID(1)))
      # Check whether the `root` is avalilable in backlog
      block:
        # ..
        discard
      # Check whether the root vertex should be created
      if createOk:
        return ok(db.bless AristoCoreDbVid(
          createOk: true,
          expHash: root))
      err(db.bless AristoCoreDbError(error: RootNotFound, ctx: "getRoot()")),

    newMptFn: proc(root: CoreDbVidRef, prune: bool): CoreDbRc[CoreDxMptRef] =
      let cMpt = AristoChildDbRef(
        root:     root.to(VertexID),
        prune:    prune,
        mpt:      ? db.adb.forkTop.toCoreDbRc(db, "mpt()"))
      ok(db.bless CoreDxMptRef(methods: db.mptMethods(cMpt, T))),

    newAccFn: proc(root: CoreDbVidRef, prune: bool): CoreDbRc[CoreDxAccRef] =
      let cMpt = AristoChildDbRef(
        root:     root.to(VertexID),
        prune:    prune,
        mpt:      ? db.adb.forkTop.toCoreDbRc(db, "mpt()"))
      ok(db.bless CoreDxAccRef(methods: db.accMethods(cMpt, T))),

    getIdFn: proc(): CoreDbRc[CoreDxTxID] =
      let aTx = ? db.adb.txTop.toCoreDbRc(db, "getId()")
      let kTx = ? db.kdb.txTop.toCoreDbRc(db, "getId()")
      ok(db.bless CoreDxTxID(methods: db.tidMethods(aTx, kTx))),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      let aTx = ? db.adb.txBeginSpan.toCoreDbRc(db, "begin()")
      let kTx = ? db.kdb.txBegin    .toCoreDbRc(db, "begin()")
      ok(db.bless CoreDxTxRef(methods: db.txMethods(aTx, kTx))),

    captureFn: proc(flags: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] =
      CoreDxCaptRef.notImplemented(db, "capture()"))

# ------------------------------------------------------------------------------
# Private  constructor helpers
# ------------------------------------------------------------------------------

proc create(
    dbType: CoreDbType;
    kdb: KvtDbRef;
    K: typedesc;
    adb: AristoDbRef;
    A: typedesc;
      ): CoreDbRef =
  ## Constructor helper

  # Local extensions
  let db = AristoCoreDbRef(
    kdb: kdb,
    adb: adb)

   # Base descriptor
  db.dbType = dbType
  db.methods = db.baseMethods A
  db.bless

proc init(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    qlr: QidLayoutRef;
      ): CoreDbRef =
  dbType.create(KvtDbRef.init(K), K, AristoDbRef.init(A, qlr), A)

proc init(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
      ): CoreDbRef =
  dbType.create(KvtDbRef.init(K), K, AristoDbRef.init(A), A)

# ------------------------------------------------------------------------------
# Public constructor helpers
# ------------------------------------------------------------------------------

proc init*(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    path: string;
    qlr: QidLayoutRef;
      ): CoreDbRef =
  dbType.create(
    KvtDbRef.init(K, path).expect "Kvt/RocksDB init() failed", K,
    AristoDbRef.init(A, path, qlr).expect "Aristo/RocksDB init() failed", A)

proc init*(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    path: string;
      ): CoreDbRef =
  dbType.create(
    KvtDbRef.init(K, path).expect "Kvt/RocksDB init() failed", K,
    AristoDbRef.init(A, path).expect "Aristo/RocksDB init() failed", A)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newAristoMemoryCoreDbRef*(qlr: QidLayoutRef): CoreDbRef =
  AristoDbMemory.init(kvt.MemBackendRef, aristo.MemBackendRef, qlr)

proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  AristoDbMemory.init(kvt.MemBackendRef, aristo.MemBackendRef)

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.init(kvt.VoidBackendRef, aristo.VoidBackendRef)

# ------------------------------------------------------------------------------
# Public helpers for direct backend access
# ------------------------------------------------------------------------------

func isAristo*(be: CoreDbRef): bool =
  be.dbType in {AristoDbMemory, AristoDbRocks, AristoDbVoid}

func toAristo*(be: CoreDbKvtBackendRef): KvtDbRef =
  if be.parent.isAristo:
    return be.AristoCoreDbKvtBE.kdb

func toAristo*(be: CoreDbMptBackendRef): AristoDbRef =
  if be.parent.isAristo:
    return be.AristoCoreDbMptBE.adb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
