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
  chronicles,
  eth/common,
  results,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  AristoBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    adb: AristoDbRef             ## Aristo MPT database
    gq: seq[AristoChildDbRef]    ## Garbage queue, deferred disposal

  AristoChildDbRef = ref AristoChildDbObj
  AristoChildDbObj = object
    ## Sub-handle for triggering destructor when it goes out of scope
    base: AristoBaseRef          ## Local base descriptor
    root: VertexID               ## State root
    prune: bool                  ## Currently unused
    mpt: AristoDbRef             ## Descriptor, may be copy of `base.adb`
    saveMode: CoreDbSaveFlags    ## When to store/discard

  AristoCoreDxMptRef = ref object of CoreDxMptRef
    ## Some extendion to recover embedded state
    ctx: AristoChildDbRef        ## Embedded state, typical var name: `cMpt`

  AristoCoreDbVid* = ref object of CoreDbVidRef
    ## Vertex ID wrapper, optinally with *MPT* context
    ctx: AristoDbRef             ## Optional *MPT* context, might be `nil`
    aVid: VertexID               ## Refers to root vertex
    createOk: bool               ## Create new root vertex when appropriate
    expHash: Hash256             ## Deferred validation

  AristoCoreDbMptBE* = ref object of CoreDbMptBackendRef
    adb*: AristoDbRef

  AristoCoreDbAccBE* = ref object of CoreDbAccBackendRef
    adb*: AristoDbRef

logScope:
  topics = "aristo-hdl"

proc gc*(base: AristoBaseRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb/adb " & info

func isValid(vid: CoreDbVidRef): bool =
  not vid.isNil and vid.ready

func to*(vid: CoreDbVidRef; T: type VertexID): T =
  if vid.isValid:
    return vid.AristoCoreDbVid.aVid

func createOk(vid: CoreDbVidRef): bool =
  if vid.isValid:
    return vid.AristoCoreDbVid.createOk

# --------------

func toCoreDbAccount(
    cMpt: AristoChildDbRef;
    acc: AristoAccount;
      ): CoreDbAccount =
  let db = cMpt.base.parent
  CoreDbAccount(
    nonce:      acc.nonce,
    balance:    acc.balance,
    codeHash:   acc.codeHash,
    storageVid: db.bless AristoCoreDbVid(ctx: cMpt.mpt, aVid: acc.storageID))

func toPayloadRef(acc: CoreDbAccount): PayloadRef =
  PayloadRef(
    pType:       AccountData,
    account: AristoAccount(
      nonce:     acc.nonce,
      balance:   acc.balance,
      storageID: acc.storageVid.to(VertexID),
      codeHash:  acc.codeHash))

# --------------

func toErrorImpl(
    e: AristoError;
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aErr:     e))

func toErrorImpl(
    e: (VertexID,AristoError);
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  db.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aVid:     e[0],
    aErr:     e[1]))


func toRcImpl[T](
    rc: Result[T,(VertexID,AristoError)];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err rc.error.toErrorImpl(db, info, error)

func toRcImpl[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err((VertexID(0),rc.error).toErrorImpl(db, info, error))


func toVoidRcImpl[T](
    rc: Result[T,(VertexID,AristoError)];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toErrorImpl(db, info, error)

func toVoidRcImpl[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err((VertexID(0),rc.error).toErrorImpl(db, info, error))

# ------------------------------------------------------------------------------
# Private call back functions  (too large for keeping inline)
# ------------------------------------------------------------------------------

proc finish(
    cMpt: AristoChildDbRef;
    info: static[string];
      ): CoreDbRc[void] =
  ## Hexary trie destructor to be called automagically when the argument
  ## wrapper gets out of scope.
  let
    base = cMpt.base
    db = base.parent

  result = ok()

  if cMpt.mpt != base.adb:
    let rc = cMpt.mpt.forget()
    if rc.isErr:
      result = err(rc.error.toErrorImpl(db, info))
    cMpt.mpt = AristoDbRef(nil) # disables `=destroy`

  if cMpt.saveMode == AutoSave:
    if base.adb.level == 0:
      let rc = base.adb.stow(persistent = true)
      if rc.isErr:
        result = err(rc.error.toErrorImpl(db, info))

proc `=destroy`(cMpt: var AristoChildDbObj) =
  ## Auto destructor
  if not cMpt.mpt.isNil:
    # Add to destructor batch queue unless direct reference
    if cMpt.mpt != cMpt.base.adb or
       cMpt.saveMode == AutoSave:
      cMpt.base.gq.add AristoChildDbRef(
        base:     cMpt.base,
        mpt:      cMpt.mpt,
        saveMode: cMpt.saveMode)

# -------------------------------

proc mptFetch(
    cMpt: AristoChildDbRef;
    k: openArray[byte];
    info: static[string];
      ): CoreDbRc[Blob] =
  let
    db = cMpt.base.parent
    rc = cMpt.mpt.fetchPayload(cMpt.root, k)
  if rc.isOk:
    return cMpt.mpt.serialise(rc.value).toRcImpl(db, info)

  if rc.error[1] != FetchPathNotFound:
    return err(rc.error.toErrorImpl(db, info))

  err rc.error.toErrorImpl(db, info, MptNotFound)


proc mptMerge(
    cMpt: AristoChildDbRef;
    k: openArray[byte];
    v: openArray[byte];
    info: static[string];
      ): CoreDbRc[void] =
  let rc = cMpt.mpt.merge(cMpt.root, k, v)
  if rc.isErr:
    return err(rc.error.toErrorImpl(cMpt.base.parent, info))
  ok()


proc mptDelete(
    cMpt: AristoChildDbRef;
    k: openArray[byte];
    info: static[string];
      ): CoreDbRc[void] =
  let rc = cMpt.mpt.delete(cMpt.root, k)
  if rc.isErr:
    return err(rc.error.toErrorImpl(cMpt.base.parent, info))
  ok()

# -------------------------------

proc accFetch(
    cMpt: AristoChildDbRef;
    address: EthAddress;
    info: static[string];
      ): CoreDbRc[CoreDbAccount] =
  let
    db = cMpt.base.parent
    pyl = block:
      let rc = cMpt.mpt.fetchPayload(cMpt.root, address.keccakHash.data)
      if rc.isOk:
        rc.value
      elif rc.error[1] != FetchPathNotFound:
        return err(rc.error.toErrorImpl(db, info))
      else:
        return err(rc.error.toErrorImpl(db, info, AccNotFound))

  if pyl.pType != AccountData:
    let vePair = (pyl.account.storageID, PayloadTypeUnsupported)
    return err(vePair.toErrorImpl(db, info & "/" & $pyl.pType))

  ok cMpt.toCoreDbAccount pyl.account


proc accMerge(
    cMpt: AristoChildDbRef;
    address: EthAddress;
    acc: CoreDbAccount;
    info: static[string];
      ): CoreDbRc[void] =
  let
    key = address.keccakHash.data
    val = acc.toPayloadRef()
    rc = cMpt.mpt.merge(cMpt.root, key, val)
  if rc.isErr:
    return rc.toVoidRcImpl(cMpt.base.parent, info)
  ok()


proc accDelete(
    cMpt: AristoChildDbRef;
    address: EthAddress;
    info: static[string];
      ): CoreDbRc[void] =
  let
    key = address.keccakHash.data
    rc = cMpt.mpt.delete(cMpt.root, key)
  if rc.isErr:
    return rc.toVoidRcImpl(cMpt.base.parent, info)
  ok()

# ------------------------------------------------------------------------------
# Private database methods function tables
# ------------------------------------------------------------------------------

proc mptMethods(cMpt: AristoChildDbRef): CoreDbMptFns =
  ## Hexary trie database handlers
  let db = cMpt.base.parent
  CoreDbMptFns(
    backendFn: proc(): CoreDbMptBackendRef =
      AristoCoreDbMptBE(adb: cMpt.mpt),

    fetchFn: proc(k: openArray[byte]): CoreDbRc[Blob] =
      cMpt.mptFetch(k, "fetchFn()"),

    deleteFn: proc(k: openArray[byte]): CoreDbRc[void] =
      cMpt.mptDelete(k, "deleteFn()"),

    mergeFn: proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      cMpt.mptMerge(k, v, "mergeFn()"),

    hasPathFn: proc(k: openArray[byte]): CoreDbRc[bool] =
      cMpt.mpt.hasPath(cMpt.root, k).toRcImpl(db, "hasPathFn()"),

    rootVidFn: proc(): CoreDbVidRef =
      var w = AristoCoreDbVid(ctx: cMpt.mpt, aVid: cMpt.root)
      db.bless(w),

    isPruningFn: proc(): bool =
      cMpt.prune,

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      cMpt.base.gc()
      result = cMpt.finish "destroyFn()"
      cMpt.mpt = AristoDbRef(nil), # Disables `=destroy()` action

    pairsIt: iterator: (Blob,Blob) =
      for (k,v) in cMpt.mpt.right LeafTie(root: cMpt.root):
        yield (k.path.pathAsBlob, cMpt.mpt.serialise(v).valueOr(EmptyBlob)),

    replicateIt: iterator: (Blob,Blob) {.gcsafe, raises: [AristoApiRlpError].} =
      discard)

proc accMethods(cMpt: AristoChildDbRef): CoreDbAccFns =
  ## Hexary trie database handlers
  let db = cMpt.base.parent
  CoreDbAccFns(
    backendFn: proc(): CoreDbAccBackendRef =
      db.bless(AristoCoreDbAccBE(adb: cMpt.mpt)),

    fetchFn: proc(address: EthAddress): CoreDbRc[CoreDbAccount] =
      cMpt.accFetch(address, "fetchFn()"),

    deleteFn: proc(address: EthAddress): CoreDbRc[void] =
      cMpt.mptDelete(address, "deleteFn()"),

    mergeFn: proc(address: EthAddress; acc: CoreDbAccount): CoreDbRc[void] =
      cMpt.accMerge(address, acc, "mergeFn()"),

    hasPathFn: proc(address: EthAddress): CoreDbRc[bool] =
      let key = address.keccakHash.data
      cMpt.mpt.hasPath(cMpt.root, key).toRcImpl(db, "hasPathFn()"),

    rootVidFn: proc(): CoreDbVidRef =
      db.bless(AristoCoreDbVid(ctx: cMpt.mpt, aVid: cMpt.root)),

    isPruningFn: proc(): bool =
      cMpt.prune,

    destroyFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[void] =
      cMpt.base.gc()
      result = cMpt.finish "destroyFn()"
      cMpt.mpt = AristoDbRef(nil)) # Disables `=destroy()` action

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

func toError*(
    e: (VertexID,AristoError);
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  e.toErrorImpl(db, info, error)

func toVoidRc*[T](
    rc: Result[T,AristoError];
    db: CoreDbRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  rc.toVoidRcImpl(db, info, error)

proc gc*(base: AristoBaseRef) =
  ## Run deferred destructors when it is safe. It is needed to run the
  ## destructors at the same scheduler level as the API call back functions.
  ## Any of the API functions can be intercepted by the `=destroy()` hook at
  ## inconvenient times so that atomicity would be violated if the actual
  ## destruction took place in `=destroy()`.
  ##
  ## Note: In practice the `db.gq` queue should not have much more than one
  ##       entry and mostly be empty.
  const info = "gc()"
  while 0 < base.gq.len:
    var q: typeof base.gq
    base.gq.swap q # now `=destroy()` may refill while destructing, below
    for cMpt in q:
      cMpt.finish(info).isOkOr:
        debug logTxt info, `error`=error.errorPrint
        continue # terminates `isOkOr()`

func mpt*(dsc: CoreDxMptRef): AristoDbRef =
  dsc.AristoCoreDxMptRef.ctx.mpt

func rootID*(dsc: CoreDxMptRef): VertexID  =
  dsc.AristoCoreDxMptRef.ctx.root

# ---------------------

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.adb.txTop.toRcImpl(base.parent, info)

func txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.adb.txBegin.toRcImpl(base.parent, info)


proc getHash*(
    base: AristoBaseRef;
    vid: CoreDbVidRef;
    update: bool;
    info: static[string];
      ): CoreDbRc[Hash256] =
  let
    db = base.parent
    aVid = vid.to(VertexID)

  if not aVid.isValid:
    return ok(EMPTY_ROOT_HASH)

  let mpt = vid.AristoCoreDbVid.ctx
  if update:
    ? mpt.hashify.toVoidRcImpl(db, info, HashNotAvailable)

  let key = block:
    let rc = mpt.getKeyRc aVid
    if rc.isErr:
      doAssert rc.error in {GetKeyNotFound,GetKeyTempLocked}
      return err(rc.error.toErrorImpl(db, info, HashNotAvailable))
    rc.value

  ok key.to(Hash256)


proc getVid*(
    base: AristoBaseRef;
    root: Hash256;
    createOk: bool;
    info: static[string];
      ): CoreDbRc[CoreDbVidRef] =
  let
    db = base.parent
    adb = base.adb

  if root == VOID_CODE_HASH:
    return ok(db.bless AristoCoreDbVid())

  block:
    base.gc() # update pending changes
    let rc = adb.hashify()
    ? adb.hashify.toVoidRcImpl(db, info, HashNotAvailable)

  # Check whether hash is available as state root on main trie
  block:
    let rc = adb.getKeyRc VertexID(1)
    if rc.isErr:
      doAssert rc.error == GetKeyNotFound
    elif rc.value == root.to(HashKey):
      return ok(db.bless AristoCoreDbVid(aVid: VertexID(1), ctx: adb))
    else:
      discard

  # Check whether the `root` is avalilable in backlog
  block:
    # ..
    discard

  # Check whether the root vertex should be created
  if createOk:
    return ok(db.bless AristoCoreDbVid(createOk: true, expHash: root))

  err(aristo.GenericError.toErrorImpl(db, info, RootNotFound))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc newMptHandler*(
    base: AristoBaseRef;
    root: CoreDbVidRef;
    prune: bool;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxMptRef] =
  base.gc()

  var rootID = root.to(VertexID)
  if not rootID.isValid:
    let rc = base.adb.getKeyRc VertexID(1)
    if rc.isErr and rc.error == GetKeyNotFound:
      rootID = VertexID(1)

  let
    db = base.parent

    (mode, mpt) = block:
      if saveMode == Companion:
        (saveMode, ? base.adb.forkTop.toRcImpl(db, info))
      elif base.adb.backend.isNil:
        (Cached, base.adb)
      else:
        (saveMode, base.adb)

    cMpt = AristoChildDbRef(
      base:     base,
      root:     rootID,
      prune:    prune,
      mpt:      mpt,
      saveMode: mode)

    dsc = AristoCoreDxMptRef(
      ctx:      cMpt,
      methods:  cMpt.mptMethods)

  ok(db.bless dsc)


proc newAccHandler*(
    base: AristoBaseRef;
    prune: bool;
    saveMode: CoreDbSaveFlags;
    info: static[string];
      ): CoreDbRc[CoreDxAccRef] =
  base.gc()

  let
    db = base.parent

    (mode, mpt) = block:
      if saveMode == Companion:
        (saveMode, ? base.adb.forkTop.toRcImpl(db, info))
      elif base.adb.backend.isNil:
        (Cached, base.adb)
      else:
        (saveMode, base.adb)

    cMpt = AristoChildDbRef(
      base:     base,
      root:     VertexID(1),
      prune:    prune,
      mpt:      mpt,
      saveMode: mode)

  ok(db.bless CoreDxAccRef(methods: cMpt.accMethods))


proc destroy*(base: AristoBaseRef; flush: bool) =
  base.gc()
  base.adb.finish(flush)


func init*(T: type AristoBaseRef; db: CoreDbRef; adb: AristoDbRef): T =
  T(parent: db, adb: adb)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
