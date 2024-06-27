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
  chronicles,
  eth/common,
  stew/byteutils,
  ../../../aristo,
  ../../../aristo/aristo_desc,
  ../../base,
  ../../base/base_desc,
  ./common_desc

type
  AristoBaseRef* = ref object
    parent: CoreDbRef            ## Opaque top level descriptor
    api*: AristoApiRef           ## Api functions can be re-directed
    ctx*: AristoCoreDbCtxRef     ## Currently active context

  AristoCoreDbCtxRef* = ref object of CoreDbCtxRef
    base: AristoBaseRef          ## Local base descriptor
    mpt*: AristoDbRef            ## Aristo MPT database

  AristoCoreDbAccRef = ref object of CoreDbAccRef
    base: AristoBaseRef          ## Local base descriptor

  AristoCoreDbMptRef = ref object of CoreDbMptRef
    base: AristoBaseRef          ## Local base descriptor
    mptRoot: VertexID            ## State root, may be zero unless account

  AristoCoreDbMptBE* = ref object of CoreDbMptBackendRef
    adb*: AristoDbRef

  AristoCoreDbAccBE* = ref object of CoreDbAccBackendRef
    adb*: AristoDbRef

logScope:
  topics = "aristo-hdl"

static:
  doAssert high(CoreDbColType).ord < LEAST_FREE_VID

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func to(eAddr: EthAddress; T: type PathID): T =
  HashKey.fromBytes(eAddr.keccakHash.data).value.to(T)

template toOpenArrayKey(eAddr: EthAddress): openArray[byte] =
  eAddr.keccakHash.data.toOpenArray(0,31)

# -------------------------------

func toError(
    e: AristoError;
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    aErr:     e))

func toError(
    e: (VertexID,AristoError);
    base: AristoBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, AristoCoreDbError(
    ctx:      info,
    isAristo: true,
    vid:      e[0],
    aErr:     e[1]))

func toRc[T](
    rc: Result[T,AristoError];
    base: AristoBaseRef;
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
    base: AristoBaseRef;
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
  template base: untyped = cMpt.base
  template db: untyped = base.parent   # Ditto
  template api: untyped = base.api     # Ditto
  template mpt: untyped = base.ctx.mpt # Ditto

  proc mptBackend(cMpt: AristoCoreDbMptRef): CoreDbMptBackendRef =
    db.bless AristoCoreDbMptBE(adb: mpt)

  proc mptFetch(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[Blob] =
    const info = "fetchFn()"
    let data = api.fetchGenericData(mpt, cMpt.mptRoot, key).valueOr:
      if error == FetchPathNotFound:
        return err(error.toError(base, info, MptNotFound))
      return err(error.toError(base, info))
    ok(data)

  proc mptMerge(cMpt: AristoCoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
    const info = "mergeFn()"
    api.mergeGenericData(mpt, cMpt.mptRoot, k, v).isOkOr:
      return err(error.toError(base, info))
    ok()

  proc mptDelete(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[void] =
    const info = "deleteFn()"
    api.deleteGenericData(mpt, cMpt.mptRoot, key).isOkOr:
      if error == DelPathNotFound:
        return err(error.toError(base, info, MptNotFound))
      return err(error.toError(base, info))
    ok()

  proc mptHasPath(cMpt: AristoCoreDbMptRef, key: openArray[byte]): CoreDbRc[bool] =
    const info = "hasPathFn()"
    let yn = api.hasPathGeneric(mpt, cMpt.mptRoot, key).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc mptState(cMpt: AristoCoreDbMptRef, updateOk: bool): CoreDbRc[Hash256] =
    const info = "mptState()"

    let rc = api.fetchGenericState(mpt, cMpt.mptRoot)
    if rc.isOk:
      return ok(rc.value)
    elif not updateOk and rc.error != GetKeyUpdateNeeded:
      return err(rc.error.toError(base, info))

    # FIXME: `hashify()` should probably throw an assert on failure
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    let state = api.fetchGenericState(mpt, cMpt.mptRoot).valueOr:
      raiseAssert info & ": " & $error
    ok(state)

  ## Generic columns database handlers
  CoreDbMptFns(
    backendFn: proc(cMpt: CoreDbMptRef): CoreDbMptBackendRef =
      mptBackend(AristoCoreDbMptRef(cMpt)),

    fetchFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[Blob] =
      mptFetch(AristoCoreDbMptRef(cMpt), k),

    deleteFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[void] =
      mptDelete(AristoCoreDbMptRef(cMpt), k),

    mergeFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mptMerge(AristoCoreDbMptRef(cMpt), k, v),

    hasPathFn: proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[bool] =
      mptHasPath(AristoCoreDbMptRef(cMpt), k),

    stateFn: proc(cMpt: CoreDbMptRef, updateOk: bool): CoreDbRc[Hash256] =
      mptState(AristoCoreDbMptRef(cMpt), updateOk))

# ------------------------------------------------------------------------------
# Private account call back functions
# ------------------------------------------------------------------------------

proc accMethods(): CoreDbAccFns =
  ## Account columns database handlers
  template base: untyped = cAcc.base
  template db: untyped = base.parent
  template api: untyped = base.api
  template mpt: untyped = base.ctx.mpt

  proc accBackend(cAcc: AristoCoreDbAccRef): CoreDbAccBackendRef =
    db.bless AristoCoreDbAccBE(adb: mpt)

  proc accFetch(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
      eAddr: EthAddress;
        ): CoreDbRc[CoreDbAccount] =
    const info = "acc/fetchFn()"

    let acc = api.fetchAccountRecord(mpt, accPath).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, AccNotFound))
    ok CoreDbAccount(
      address:  eAddr,
      nonce:    acc.nonce,
      balance:  acc.balance,
      codeHash: acc.codeHash)
    
  proc accMerge(
      cAcc: AristoCoreDbAccRef;
      acc: CoreDbAccount;
        ): CoreDbRc[void] =
    const info = "acc/mergeFn()"

    let
      key = acc.address.keccakHash.data
      val = AristoAccount(
        nonce:    acc.nonce,
        balance:  acc.balance,
        codeHash: acc.codeHash)
    api.mergeAccountRecord(mpt, key, val).isOkOr:
      return err(error.toError(base, info))
    ok()

  proc accDelete(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
        ): CoreDbRc[void] =
    const info = "acc/deleteFn()"

    api.deleteAccountRecord(mpt, accPath).isOkOr:
      if error == DelPathNotFound:
        # TODO: Would it be conseqient to just return `ok()` here?
        return err(error.toError(base, info, AccNotFound))
      return err(error.toError(base, info))
    ok()

  proc accClearStorage(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
        ): CoreDbRc[void] =
    const info = "acc/clearStoFn()"

    api.deleteStorageTree(mpt, accPath).isOkOr:
      if error notin {DelStoRootMissing,DelStoAccMissing}:
        return err(error.toError(base, info))
    ok()

  proc accHasPath(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
        ): CoreDbRc[bool] =
    const info = "hasPathFn()"

    let yn = api.hasPathAccount(mpt, accPath).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc accState(
      cAcc: AristoCoreDbAccRef,
      updateOk: bool;
        ): CoreDbRc[Hash256] =
    const info = "accStateFn()"

    let rc = api.fetchAccountState(mpt)
    if rc.isOk:
      return ok(rc.value)
    elif not updateOk and rc.error != GetKeyUpdateNeeded:
      return err(rc.error.toError(base, info))

    # FIXME: `hashify()` should probably throw an assert on failure
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    let state = api.fetchAccountState(mpt).valueOr:
      raiseAssert info & ": " & $error
    ok(state)


  proc slotFetch(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
      stoPath: openArray[byte];
        ): CoreDbRc[Blob] =
    const info = "slotFetchFn()"

    let data = api.fetchStorageData(mpt, accPath, stoPath).valueOr:
      if error != FetchPathNotFound:
        return err(error.toError(base, info))
      return err(error.toError(base, info, StoNotFound))
    ok(data)

  proc slotDelete(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
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
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
      stoPath: openArray[byte];
        ): CoreDbRc[bool] =
    const info = "slotHasPathFn()"

    let yn = api.hasPathStorage(mpt, accPath, stoPath).valueOr:
      return err(error.toError(base, info))
    ok(yn)

  proc slotMerge(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
      stoPath: openArray[byte]; 
      stoData: openArray[byte];
        ): CoreDbRc[void] =
    const info = "slotMergeFn()"

    api.mergeStorageData(mpt, accPath, stoPath, stoData).isOkOr:
        return err(error.toError(base, info))
    ok()

  proc slotState(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
      updateOk: bool;
        ): CoreDbRc[Hash256] =
    const info = "slotStateFn()"

    let rc = api.fetchStorageState(mpt, accPath)
    if rc.isOk:
      return ok(rc.value)
    elif not updateOk and rc.error != GetKeyUpdateNeeded:
      return err(rc.error.toError(base, info))

    # FIXME: `hashify()` should probably throw an assert on failure
    ? api.hashify(mpt).toVoidRc(base, info, HashNotAvailable)

    let state = api.fetchStorageState(mpt, accPath).valueOr:
      return err(error.toError(base, info))
    ok(state)

  proc slotStateEmpty(
      cAcc: AristoCoreDbAccRef;
      accPath: openArray[byte];
        ): CoreDbRc[bool] =
    const info = "slotStateEmptyFn()"

    let yn = api.hasStorageData(mpt, accPath).valueOr:
      return err(error.toError(base, info))
    ok(not yn)


  CoreDbAccFns(
    backendFn: proc(cAcc: CoreDbAccRef): CoreDbAccBackendRef =
      accBackend(AristoCoreDbAccRef(cAcc)),

    fetchFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
          ): CoreDbRc[CoreDbAccount] =
      accFetch(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey, eAddr),

    deleteFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
          ): CoreDbRc[void] =
      accDelete(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey),

    clearStorageFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
          ): CoreDbRc[void] =
      accClearStorage(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey),

    mergeFn: proc(
        cAcc: CoreDbAccRef;
        acc: CoreDbAccount;
          ): CoreDbRc[void] =
      accMerge(AristoCoreDbAccRef(cAcc), acc),

    hasPathFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
          ): CoreDbRc[bool] =
      accHasPath(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey),

    stateFn: proc(
        cAcc: CoreDbAccRef;
        updateOk: bool;
          ): CoreDbRc[Hash256] =
      accState(AristoCoreDbAccRef(cAcc), updateOk),

    slotFetchFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
        stoPath: openArray[byte];
          ): CoreDbRc[Blob] =
      slotFetch(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey, stoPath),

    slotDeleteFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
        stoPath: openArray[byte];
          ): CoreDbRc[void] =
      slotDelete(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey, stoPath),

    slotHasPathFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
        stoPath: openArray[byte];
          ): CoreDbRc[bool] =
      slotHasPath(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey, stoPath),

    slotMergeFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
        stoPath: openArray[byte];
        stoData: openArray[byte];
          ): CoreDbRc[void] =
      slotMerge(AristoCoreDbAccRef(cAcc),
                eAddr.toOpenArrayKey, stoPath, stoData),

    slotStateFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
        updateOk: bool;
           ): CoreDbRc[Hash256] =
      slotState(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey, updateOk),

    slotStateEmptyFn: proc(
        cAcc: CoreDbAccRef;
        eAddr: EthAddress;
           ): CoreDbRc[bool] =
      slotStateEmpty(AristoCoreDbAccRef(cAcc), eAddr.toOpenArrayKey))

# ------------------------------------------------------------------------------
# Private context call back functions
# ------------------------------------------------------------------------------

proc ctxMethods(): CoreDbCtxFns =
  template base: untyped = cCtx.base
  template db: untyped = base.parent
  template api: untyped = base.api
  template mpt: untyped = cCtx.mpt

  proc ctxGetColumn(cCtx: AristoCoreDbCtxRef; colType: CoreDbColType; clearData: bool): CoreDbMptRef =
    const info = "getColumnFn()"
    if clearData:
      api.deleteGenericTree(mpt, VertexID(colType)).isOkOr:
        raiseAssert info & " clearing up failed: " & $error
    db.bless AristoCoreDbMptRef(
      methods: mptMethods(),
      base:    base,
      mptRoot: VertexID(colType))

  proc ctxGetAccounts(cCtx: AristoCoreDbCtxRef): CoreDbAccRef =
    db.bless AristoCoreDbAccRef(
      methods: accMethods(),
      base:    base)

  proc ctxForget(cCtx: AristoCoreDbCtxRef) =
    api.forget(mpt).isOkOr:
      raiseAssert "forgetFn(): " & $error


  CoreDbCtxFns(
    getColumnFn: proc(cCtx: CoreDbCtxRef; colType: CoreDbColType; clearData: bool): CoreDbMptRef =
      ctxGetColumn(AristoCoreDbCtxRef(cCtx), colType, clearData),

    getAccountsFn: proc(cCtx: CoreDbCtxRef): CoreDbAccRef =
      ctxGetAccounts(AristoCoreDbCtxRef(cCtx)),

    forgetFn: proc(cCtx: CoreDbCtxRef) =
      ctxForget(AristoCoreDbCtxRef(cCtx)))

# ------------------------------------------------------------------------------
# Public handlers and helpers
# ------------------------------------------------------------------------------

proc getSavedState*(base: AristoBaseRef): Result[SavedState,void] =
  let be = base.ctx.mpt.backend
  if not be.isNil:
    let rc = base.api.fetchLastSavedState(base.ctx.mpt)
    if rc.isOk:
      return ok(rc.value)
  err()

# ---------------------

func to*(dsc: CoreDbMptRef, T: type AristoDbRef): T =
  AristoCoreDbMptRef(dsc).base.ctx.mpt

func to*(dsc: CoreDbAccRef, T: type AristoDbRef): T =
  AristoCoreDbAccRef(dsc).base.ctx.mpt

func to*(dsc: CoreDbMptRef, T: type AristoApiRef): T =
  AristoCoreDbMptRef(dsc).base.api

func to*(dsc: CoreDbAccRef, T: type AristoApiRef): T =
  AristoCoreDbAccRef(dsc).base.api

func rootID*(dsc: CoreDbMptRef): VertexID  =
  AristoCoreDbMptRef(dsc).mptRoot

func txTop*(
    base: AristoBaseRef;
    info: static[string];
      ): CoreDbRc[AristoTxRef] =
  base.api.txTop(base.adb).toRc(base, info)

proc txBegin*(
    base: AristoBaseRef;
    info: static[string];
      ): AristoTxRef =
  let rc = base.api.txBegin(base.ctx.mpt)
  if rc.isErr:
    raiseAssert info & ": " & $rc.error
  rc.value

proc getLevel*(base: AristoBaseRef): int =
  base.api.level(base.ctx.mpt)

# ---------------------

proc swapCtx*(base: AristoBaseRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  doAssert not ctx.isNil
  result = base.ctx

  # Set read-write access and install
  base.ctx = AristoCoreDbCtxRef(ctx)
  base.api.reCentre(base.ctx.mpt).isOkOr:
    raiseAssert "swapCtx() failed: " & $error


proc persistent*(
    base: AristoBaseRef;
    fid: uint64;
    info: static[string];
      ): CoreDbRc[void] =
  let
    api = base.api
    mpt = base.ctx.mpt
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

proc destroy*(base: AristoBaseRef; eradicate: bool) =
  base.api.finish(base.ctx.mpt, eradicate)


func init*(T: type AristoBaseRef; db: CoreDbRef; adb: AristoDbRef): T =
  result = T(
    parent: db,
    api:    AristoApiRef.init())

  # Create initial context
  let ctx = AristoCoreDbCtxRef(
    methods: ctxMethods(),
    base:    result,
    mpt:     adb)
  result.ctx = db.bless ctx

  when CoreDbEnableApiProfiling:
    let profApi = AristoApiProfRef.init(result.api, adb.backend)
    result.api = profApi
    result.ctx.mpt.backend = profApi.be


proc init*(
    T: type CoreDbCtxRef;
    base: AristoBaseRef;
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
      let rc = api.findTx(base.ctx.mpt, vid, key)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

    # Fork MPT descriptor that provides `(vid,key)`
    newMpt = block:
      let rc = api.forkTx(base.ctx.mpt, inx)
      if rc.isErr:
        return err(rc.error.toError(base, info))
      rc.value

  # Create new context
  let ctx = AristoCoreDbCtxRef(
    methods: ctxMethods(),
    base:    base,
    mpt:     newMpt)
  ok(base.parent.bless ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
