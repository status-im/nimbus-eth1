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
  std/typetraits,
  eth/common,
  stew/byteutils,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc

static:
  doAssert high(CoreDbColType).ord < LEAST_FREE_VID

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toError(
    e: AristoError;
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: true,
    aErr:     e))

func toError(
    e: (VertexID,AristoError);
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: true,
    vid:      e[0],
    aErr:     e[1]))

func toRc[T](
    rc: Result[T,AristoError];
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[T] =
  if rc.isOk:
    when T is void:
      return ok()
    else:
      return ok(rc.value)
  err((VertexID(0),rc.error).toError(base, info, error))

func toVoidRc[T](
    rc: Result[T,(VertexID,AristoError)];
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbRc[void] =
  if rc.isOk:
    return ok()
  err rc.error.toError(base, info, error)

# ------------------------------------------------------------------------------
# Private `MPT` call back functions
# ------------------------------------------------------------------------------

proc mptMethods(): CoreDbMptFns =
  # These templates are a hack to remove a closure environment that was using
  # hundreds of mb of memory to have this syntactic convenience
  # TODO remove methods / abstraction entirely - it is no longer needed
  template db: untyped = cMpt.parent
  template base: untyped = db.adbBase
  template api: untyped = base.api
  template mpt: untyped = db.ctx.mpt

  proc mptBackend(cMpt: CoreDbMptRef): CoreDbMptBackendRef =
    db.bless CoreDbMptBackendRef(adb: mpt)

  proc mptFetch(cMpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[Blob] =
    const info = "fetchFn()"
    let data = api.fetchGenericData(mpt, cMpt.rootID, key).valueOr:
      if error == FetchPathNotFound:
        return err(error.toError(base, info, MptNotFound))
      return err(error.toError(base, info))
    ok(data)

  proc mptMerge(cMpt: CoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
    const info = "mergeFn()"
    api.mergeGenericData(mpt, cMpt.rootID, k, v).isOkOr:
      return err(error.toError(base, info))
    ok()

  proc mptDelete(cMpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[void] =
    const info = "deleteFn()"
    api.deleteGenericData(mpt, cMpt.rootID, key).isOkOr:
      if error == DelPathNotFound:
        return err(error.toError(base, info, MptNotFound))
      return err(error.toError(base, info))
    ok()

  proc mptHasPath(cMpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[bool] =
    const info = "hasPathFn()"
    let yn = api.hasPathGeneric(mpt, cMpt.rootID, key).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc mptState(cMpt: CoreDbMptRef, updateOk: bool): CoreDbRc[Hash256] =
    const info = "mptState()"
    let state = api.fetchGenericState(mpt, cMpt.rootID, updateOk).valueOr:
      return err(error.toError(base, info))
    ok(state)

  ## Generic columns database handlers
  CoreDbMptFns(
    backendFn: proc(cMpt: CoreDbMptRef): CoreDbMptBackendRef =
      mptBackend(CoreDbMptRef(cMpt)),

    fetchFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[Blob] =
      mptFetch(CoreDbMptRef(cMpt), k),

    deleteFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[void] =
      mptDelete(CoreDbMptRef(cMpt), k),

    mergeFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mptMerge(CoreDbMptRef(cMpt), k, v),

    hasPathFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[bool] =
      mptHasPath(CoreDbMptRef(cMpt), k),

    stateFn: proc(cMpt: CoreDbMptRef, updateOk: bool): CoreDbRc[Hash256] =
      mptState(CoreDbMptRef(cMpt), updateOk))

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(): CoreDbAccFns =
  ## Account columns database handlers
  template db: untyped = cAcc.parent
  template base: untyped = db.adbBase
  template api: untyped = base.api
  template mpt: untyped = db.ctx.mpt

  proc accBackend(cAcc: CoreDbAccRef): CoreDbAccBackendRef =
    db.bless CoreDbAccBackendRef(adb: mpt)

  proc accFetch(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
        ): CoreDbRc[CoreDbAccount] =
    const info = "acc/fetchFn()"

    let acc = api.fetchAccountRecord(mpt, accPath).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, AccNotFound))
    ok acc

  proc accMerge(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      accRec: CoreDbAccount;
        ): CoreDbRc[void] =
    const info = "acc/mergeFn()"

    let val = AristoAccount(
      nonce:    accRec.nonce,
      balance:  accRec.balance,
      codeHash: accRec.codeHash)
    api.mergeAccountRecord(mpt, accPath, val).isOkOr:
      return err(error.toError(base, info))
    ok()

  proc accDelete(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
        ): CoreDbRc[void] =
    const info = "acc/deleteFn()"

    api.deleteAccountRecord(mpt, accPath).isOkOr:
      if error == DelPathNotFound:
        # TODO: Would it be conseqient to just return `ok()` here?
        return err(error.toError(base, info, AccNotFound))
      return err(error.toError(base, info))
    ok()

  proc accClearStorage(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
        ): CoreDbRc[void] =
    const info = "acc/clearStoFn()"

    api.deleteStorageTree(mpt, accPath).isOkOr:
      if error notin {DelStoRootMissing,DelStoAccMissing}:
        return err(error.toError(base, info))
    ok()

  proc accHasPath(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
        ): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let yn = api.hasPathAccount(mpt, accPath).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc accState(
      cAcc: CoreDbAccRef,
      updateOk: bool;
        ): CoreDbRc[Hash256] =
    const info = "accStateFn()"
    let state = api.fetchAccountState(mpt, updateOk).valueOr:
      return err(error.toError(base, info))
    ok(state)


  proc slotFetch(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      stoPath: openArray[byte];
        ): CoreDbRc[Blob] =
    const info = "slotFetchFn()"

    let data = api.fetchStorageData(mpt, accPath, stoPath).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, StoNotFound))
    ok(data)

  proc slotDelete(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      stoPath: openArray[byte];
        ): CoreDbRc[void] =
    const info = "slotDeleteFn()"

    api.deleteStorageData(mpt, accPath, stoPath).isOkOr:
      if error == DelPathNotFound:
        return err(error.toError(base, info, StoNotFound))
      if error == DelStoRootMissing:
        # This is insane but legit. A storage column was announced for an
        # account but no data have been added, yet.
        return ok()
      return err(error.toError(base, info))
    ok()

  proc slotHasPath(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      stoPath: openArray[byte];
        ): CoreDbRc[bool] =
    const info = "slotHasPathFn()"

    let yn = api.hasPathStorage(mpt, accPath, stoPath).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc slotMerge(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      stoPath: openArray[byte]; 
      stoData: openArray[byte];
        ): CoreDbRc[void] =
    const info = "slotMergeFn()"

    api.mergeStorageData(mpt, accPath, stoPath, stoData).isOkOr:
        return err(error.toError(base, info))
    ok()

  proc slotState(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
      updateOk: bool;
        ): CoreDbRc[Hash256] =
    const info = "slotStateFn()"
    let state = api.fetchStorageState(mpt, accPath, updateOk).valueOr:
      return err(error.toError(base, info))
    ok(state)

  proc slotStateEmpty(
      cAcc: CoreDbAccRef;
      accPath: Hash256;
        ): CoreDbRc[bool] =
    const info = "slotStateEmptyFn()"

    let yn = api.hasStorageData(mpt, accPath).valueOr:
      return err(error.toError(base, info))
    ok(not yn)


  CoreDbAccFns(
    backendFn: proc(cAcc: CoreDbAccRef): CoreDbAccBackendRef =
      accBackend(CoreDbAccRef(cAcc)),

    fetchFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
          ): CoreDbRc[CoreDbAccount] =
      accFetch(CoreDbAccRef(cAcc), accPath),

    deleteFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
          ): CoreDbRc[void] =
      accDelete(CoreDbAccRef(cAcc), accPath),

    clearStorageFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
          ): CoreDbRc[void] =
      accClearStorage(CoreDbAccRef(cAcc), accPath),

    mergeFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        accRec: CoreDbAccount;
          ): CoreDbRc[void] =
      accMerge(CoreDbAccRef(cAcc), accPath, accRec),

    hasPathFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
          ): CoreDbRc[bool] =
      accHasPath(CoreDbAccRef(cAcc), accPath),

    stateFn: proc(
        cAcc: CoreDbAccRef;
        updateOk: bool;
          ): CoreDbRc[Hash256] =
      accState(CoreDbAccRef(cAcc), updateOk),

    slotFetchFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        stoPath: openArray[byte];
          ): CoreDbRc[Blob] =
      slotFetch(CoreDbAccRef(cAcc), accPath, stoPath),

    slotDeleteFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        stoPath: openArray[byte];
          ): CoreDbRc[void] =
      slotDelete(CoreDbAccRef(cAcc), accPath, stoPath),

    slotHasPathFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        stoPath: openArray[byte];
          ): CoreDbRc[bool] =
      slotHasPath(CoreDbAccRef(cAcc), accPath, stoPath),

    slotMergeFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        stoPath: openArray[byte];
        stoData: openArray[byte];
          ): CoreDbRc[void] =
      slotMerge(CoreDbAccRef(cAcc), accPath, stoPath, stoData),

    slotStateFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
        updateOk: bool;
           ): CoreDbRc[Hash256] =
      slotState(CoreDbAccRef(cAcc), accPath, updateOk),

    slotStateEmptyFn: proc(
        cAcc: CoreDbAccRef;
        accPath: Hash256;
           ): CoreDbRc[bool] =
      slotStateEmpty(CoreDbAccRef(cAcc), accPath))

# ------------------------------------------------------------------------------
# Private context call back functions
# ------------------------------------------------------------------------------

proc ctxMethods(): CoreDbCtxFns =
  template db: untyped = cCtx.parent
  template base: untyped = db.adbBase
  template api: untyped = base.api
  template mpt: untyped = cCtx.mpt

  proc ctxGetColumn(cCtx: CoreDbCtxRef; colType: CoreDbColType; clearData: bool): CoreDbMptRef =
    const info = "getColumnFn()"
    if clearData:
      api.deleteGenericTree(mpt, VertexID(colType)).isOkOr:
        raiseAssert info & " clearing up failed: " & $error
    db.bless CoreDbMptRef(
      methods: mptMethods(),
      rootID: VertexID(colType))

  proc ctxGetAccounts(cCtx: CoreDbCtxRef): CoreDbAccRef =
    db.bless CoreDbAccRef(
      methods: accMethods())

  proc ctxForget(cCtx: CoreDbCtxRef) =
    api.forget(mpt).isOkOr:
      raiseAssert "forgetFn(): " & $error


  CoreDbCtxFns(
    getColumnFn: proc(cCtx: CoreDbCtxRef; colType: CoreDbColType; clearData: bool): CoreDbMptRef =
      ctxGetColumn(CoreDbCtxRef(cCtx), colType, clearData),

    getAccountsFn: proc(cCtx: CoreDbCtxRef): CoreDbAccRef =
      ctxGetAccounts(CoreDbCtxRef(cCtx)),

    forgetFn: proc(cCtx: CoreDbCtxRef) =
      ctxForget(CoreDbCtxRef(cCtx)))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

proc getSavedState*(base: CoreDbAriBaseRef): Result[SavedState,void] =
  let
    mpt = base.parent.ctx.CoreDbCtxRef.mpt
    be = mpt.backend
  if not be.isNil:
    let rc = base.api.fetchLastSavedState(mpt)
    if rc.isOk:
      return ok(rc.value)
  err()

# ---------------------

proc txBegin*(
    base: CoreDbAriBaseRef;
    info: static[string];
      ): AristoTxRef =
  let rc = base.api.txBegin(base.parent.ctx.CoreDbCtxRef.mpt)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc getLevel*(base: CoreDbAriBaseRef): int =
  base.api.level(base.parent.ctx.CoreDbCtxRef.mpt)

# ---------------------

proc swapCtx*(base: CoreDbAriBaseRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  doAssert not ctx.isNil
  result = base.parent.ctx

  # Set read-write access and install
  base.parent.ctx = CoreDbCtxRef(ctx)
  base.api.reCentre(base.parent.ctx.CoreDbCtxRef.mpt).isOkOr:
    raiseAssert "swapCtx() failed: " & $error


proc persistent*(
    base: CoreDbAriBaseRef;
    fid: uint64;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    mpt = base.parent.ctx.CoreDbCtxRef.mpt
    rc = api.persist(mpt, fid)
  if rc.isOk:
    ok()
  elif api.level(mpt) == 0:
    err(rc.error.toError(base, info))
  else:
    err(rc.error.toError(base, info, TxPending))

# ------------------------------------------------------------------------------
# Public constructors and related
# ------------------------------------------------------------------------------

proc destroy*(base: CoreDbAriBaseRef; eradicate: bool) =
  base.api.finish(base.parent.ctx.CoreDbCtxRef.mpt, eradicate)

func init*(T: type CoreDbCtxRef; db: CoreDbRef, adb: AristoDbRef): T =
  ## Create initial context
  let ctx = CoreDbCtxRef(
    methods: ctxMethods(),
    mpt:     adb)

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(db.adbBase.api, adb.backend)
    result.api = profApi
    result.ctx.mpt.backend = profApi.be

  db.bless ctx


proc init*(
    T: type CoreDbCtxRef;
    base: CoreDbAriBaseRef;
    colState: Hash256;
    colType: CoreDbColType;
      ): CoreDbRc[CoreDbCtxRef] =
  const info = "fromTxFn()"

  if colType.ord == 0:
    return err(aristo.GenericError.toError(base, info, ColUnacceptable))
  let
    api = base.api
    vid = VertexID(colType)
    key = colState.to(HashKey)

    # Find `(vid,key)` on transaction stack
    inx = block:
      let rc = api.findTx(base.parent.ctx.CoreDbCtxRef.mpt, vid, key)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = api.forkTx(base.parent.ctx.CoreDbCtxRef.mpt, inx)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

  # Create new context
  let ctx = CoreDbCtxRef(
    methods: ctxMethods(),
    mpt:     newMpt)
  ok(base.parent.bless ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
