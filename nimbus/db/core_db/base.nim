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
  eth/common,
  "../.."/[constants, errors],
  ../kvt,
  ../aristo,
  ./base/[api_tracking, base_desc]

const
  EnableApiTracking = false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Also, some `func` designators might need to
    ## be changed to `proc` for possible side effects.
    ##
    ## Tracking noise is then enabled by setting the flag `trackNewApi` to
    ## `true` in the `CoreDbRef` descriptor.

  EnableApiProfiling = true
    ## Enables functions profiling if `EnableApiTracking` is also set `true`.

  EnableDebugApi* = defined(release).not # and false
    ## ...

  AutoValidateDescriptors = defined(release).not
    ## No validatinon needed for production suite.

export
  CoreDbAccount,
  CoreDbApiError,
  CoreDbCaptFlags,
  CoreDbColType,
  CoreDbCtxRef,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbFnInx,
  CoreDbKvtBackendRef,
  CoreDbMptBackendRef,
  CoreDbPersistentTypes,
  CoreDbProfListRef,
  CoreDbRef,
  CoreDbType,
  CoreDbAccRef,
  CoreDbCaptRef,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbTxRef

const
  CoreDbEnableApiTracking* = EnableApiTracking
  CoreDbEnableApiProfiling* = EnableApiTracking and EnableApiProfiling

when AutoValidateDescriptors:
  import ./base/validate

when EnableDebugApi:
  discard
else:
  import
    ../aristo/[
      aristo_delete, aristo_desc, aristo_fetch, aristo_merge, aristo_tx],
    ../kvt/[kvt_desc, kvt_utils, kvt_tx]

# More settings
const
  logTxt = "CoreDb "
  newApiTxt = logTxt & "API"

# Annotation helpers
{.pragma:   apiRaise, gcsafe, raises: [CoreDbApiError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

proc bless*(
    db: CoreDbRef;
    error: CoreDbErrorCode;
    dsc: CoreDbErrorRef;
      ): CoreDbErrorRef
      {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when EnableApiTracking:
  when EnableApiProfiling:
    {.warning: "*** Provided API profiling for CoreDB (disabled by default)".}
  else:
    {.warning: "*** Provided API logging for CoreDB (disabled by default)".}

  import
    std/times,
    chronicles

  proc `$`[T](rc: CoreDbRc[T]): string = rc.toStr
  proc `$`(q: set[CoreDbCaptFlags]): string = q.toStr
  proc `$`(t: Duration): string = t.toStr
  proc `$`(e: EthAddress): string = e.toStr
  proc `$`(h: Hash256): string = h.toStr

template setTrackNewApi(
    w: CoreDbApiTrackRef;
    s: static[CoreDbFnInx];
    code: untyped;
      ) =
  ## Template with code section that will be discarded if logging is
  ## disabled at compile time when `EnableApiTracking` is `false`.
  when EnableApiTracking:
    w.beginNewApi(s)
    code
  const api {.inject,used.} = s

template setTrackNewApi*(
    w: CoreDbApiTrackRef;
    s: static[CoreDbFnInx];
      ) =
  w.setTrackNewApi(s):
    discard

template ifTrackNewApi*(w: CoreDbApiTrackRef; code: untyped) =
  when EnableApiTracking:
    w.endNewApiIf:
      code
# ------------------------------------------------------------------------------
# Private KVT helpers
# ------------------------------------------------------------------------------

proc toError(
    e: KvtError;
    base: CoreDbKvtBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: false,
    kErr:     e))

template call(
    base: CoreDbKvtBaseRef;
    fn: untyped;
    args: varArgs[untyped];
      ): untyped =
  when EnableDebugApi:
    base.api.fn(args)
  else:
    fn(args)

# ------------------------------------------------------------------------------
# Private Aristo helpers
# ------------------------------------------------------------------------------

proc toError(
    e: AristoError;
    base: CoreDbAriBaseRef;
    info: string;
    error = Unspecified;
      ): CoreDbErrorRef =
  base.parent.bless(error, CoreDbErrorRef(
    ctx:      info,
    isAristo: true,
    aErr:     e))

template call(
    base: CoreDbAriBaseRef;
    fn: untyped;
    args: varArgs[untyped];
      ): untyped =
  when EnableDebugApi:
    base.api.fn(args)
  else:
    fn(args)

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

proc bless*(db: CoreDbRef): CoreDbRef =
  ## Verify descriptor
  when AutoValidateDescriptors:
    db.validate
  when CoreDbEnableApiProfiling:
    db.profTab = CoreDbProfListRef.init()
  db

proc bless*(db: CoreDbRef; kvt: CoreDbKvtRef): CoreDbKvtRef =
  ## Complete sub-module descriptor, fill in `parent`.
  kvt.parent = db
  when AutoValidateDescriptors:
    kvt.validate
  kvt

proc bless*[T: CoreDbKvtRef |
               CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef |
               CoreDbTxRef  | CoreDbCaptRef |
               CoreDbKvtBaseRef | CoreDbAriBaseRef |
               CoreDbKvtBackendRef | CoreDbMptBackendRef | CoreDbAccBackendRef](
    db: CoreDbRef;
    dsc: T;
      ): auto =
  ## Complete sub-module descriptor, fill in `parent`.
  dsc.parent = db
  when AutoValidateDescriptors:
    dsc.validate
  dsc

proc bless*(
    db: CoreDbRef;
    error: CoreDbErrorCode;
    dsc: CoreDbErrorRef;
      ): CoreDbErrorRef =
  dsc.parent = db
  dsc.error = error
  when AutoValidateDescriptors:
    dsc.validate
  dsc


proc prettyText*(e: CoreDbErrorRef): string =
  ## Pretty print argument object (for tracking use `$$()`)
  if e.isNil: "$ø" else: e.toStr()

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc dbProfData*(db: CoreDbRef): CoreDbProfListRef =
  ## Return profiling data table (only available in profiling mode). If
  ## available (i.e. non-nil), result data can be organised by the functions
  ## available with `aristo_profile`.
  when CoreDbEnableApiProfiling:
    db.profTab

proc dbType*(db: CoreDbRef): CoreDbType =
  ## Getter, print DB type identifier
  ##
  db.setTrackNewApi BaseDbTypeFn
  result = db.dbType
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc parent*[T: CoreDbKvtRef |
                CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef |
                CoreDbTxRef | CoreDbCaptRef |
                CoreDbKvtBaseRef | CoreDbAriBaseRef |
                CoreDbErrorRef] (
    child: T): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = child.parent

proc finish*(db: CoreDbRef; eradicate = false) =
  ## Database destructor. If the argument `eradicate` is set `false`, the
  ## database is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  ##
  db.setTrackNewApi BaseFinishFn
  db.methods.destroyFn eradicate
  db.ifTrackNewApi: debug newApiTxt, api, elapsed

proc `$$`*(e: CoreDbErrorRef): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  ##
  e.setTrackNewApi ErrorPrintFn
  result = e.prettyText()
  e.ifTrackNewApi: debug newApiTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc backend*(kvt: CoreDbKvtRef): CoreDbKvtBackendRef =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  kvt.setTrackNewApi AnyBackendFn
  result = kvt.parent.bless CoreDbKvtBackendRef(kdb: kvt.kvt)
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed

proc newKvt*(db: CoreDbRef): CoreDbKvtRef =
  ## Constructor, will defect on failure.
  ##
  ## This function subscribes to the common base object shared with other
  ## KVT descriptors. Any changes are immediately visible to subscribers.
  ## On destruction (when the constructed object gets out of scope), changes
  ## are not saved to the backend database but are still cached and available.
  ##
  db.setTrackNewApi BaseNewKvtFn
  result = db.methods.newKvtFn().valueOr:
    raiseAssert error.prettyText()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed

# ----------- KVT ---------------

proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtGetFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(get, kvt.kvt, key)
  result = block:
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError(base, $api, KvtNotFound))
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `get()` returning an empty `Blob` if the key is not found
  ## on the database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(get, kvt.kvt, key)
  result = block:
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      CoreDbRc[Blob].ok(EmptyBlob)
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc len*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[int] =
  ## This function returns the size of the value associated with `key`.
  kvt.setTrackNewApi KvtLenFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(len, kvt.kvt, key)
  result = block:
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError(base, $api, KvtNotFound))
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(del, kvt.kvt, key)
  result = block:
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDbKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(put, kvt.kvt, key, val)
  result = block:
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi:
    debug newApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr, result

proc hasKey*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  kvt.setTrackNewApi KvtHasKeyFn
  let
    base = kvt.parent.kdbBase
    rc = base.call(hasKey, kvt.kvt, key)
  result = block:
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree context constructors and administration
# ------------------------------------------------------------------------------

proc ctx*(db: CoreDbRef): CoreDbCtxRef =
  ## Get currently active column context.
  ##
  db.setTrackNewApi BaseNewCtxFn
  result = db.methods.newCtxFn()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed

proc swapCtx*(db: CoreDbRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  ## Activate argument context `ctx` and return the previously active column
  ## context. This function goes typically together with `forget()`. A valid
  ## scenario might look like
  ## ::
  ##   proc doSomething(db: CoreDbRef; ctx: CoreDbCtxRef) =
  ##     let saved = db.swapCtx ctx
  ##     defer: db.swapCtx(saved).forget()
  ##     ...
  ##
  db.setTrackNewApi BaseSwapCtxFn
  result = db.methods.swapCtxFn ctx
  db.ifTrackNewApi: debug newApiTxt, api, elapsed

proc forget*(ctx: CoreDbCtxRef) =
  ## Dispose `ctx` argument context and related columns created with this
  ## context. This function fails if `ctx` is the default context.
  ##
  ctx.setTrackNewApi CtxForgetFn
  ctx.parent.adbBase.call(forget, ctx.mpt).isOkOr:
    raiseAssert $api & ": " & $error
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# Public functions for generic columns
# ------------------------------------------------------------------------------

proc backend*(mpt: CoreDbMptRef): CoreDbMptBackendRef =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  mpt.setTrackNewApi AnyBackendFn
  result = mpt.parent.bless CoreDbMptBackendRef(adb: mpt.parent.ctx.mpt)
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

proc getColumn*(
    ctx: CoreDbCtxRef;
    colType: CoreDbColType;
    clearData = false;
      ): CoreDbMptRef =
  ## ...
  ##
  ctx.setTrackNewApi CtxGetColumnFn
  # result = ctx.methods.getColumnFn(ctx, colType, clearData)
  let db = ctx.parent
  if clearData:
    db.adbBase.call(deleteGenericTree, ctx.mpt, VertexID(colType)).isOkOr:
      raiseAssert $api & ": " & $error
  result = db.bless CoreDbMptRef(rootID: VertexID(colType)) 
  ctx.ifTrackNewApi: debug newApiTxt, api, colType, clearData, elapsed

# ----------- generic MPT ---------------

proc fetch*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `mpt`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchGenericData, db.ctx.mpt, mpt.rootID, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError(base, $api, MptNotFound))
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc fetchOrEmpty*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchGenericData, db.ctx.mpt, mpt.rootID, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      CoreDbRc[Blob].ok(EmptyBlob)
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc delete*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(deleteGenericData, db.ctx.mpt, mpt.rootID, key)
    if rc.isOk:
      ok()
    elif rc.error == DelPathNotFound:
      err(rc.error.toError(base, $api, MptNotFound))
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc merge*(
    mpt: CoreDbMptRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(mergeGenericData, db.ctx.mpt, mpt.rootID, key, val)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi:
    debug newApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr, result

proc hasPath*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(hasPathGeneric, db.ctx.mpt, mpt.rootID, key)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc state*(mpt: CoreDbMptRef; updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the argument
  ## database column (if acvailable.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  mpt.setTrackNewApi MptStateFn
  #result = mpt.methods.stateFn(mpt, updateOk)
  let
    db = mpt.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchGenericState, db.ctx.mpt, mpt.rootID, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, updateOK, result

# ------------------------------------------------------------------------------
# Public methods for accounts
# ------------------------------------------------------------------------------

proc backend*(acc: CoreDbAccRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  acc.setTrackNewApi AnyBackendFn
  result = acc.parent.bless CoreDbAccBackendRef(adb: acc.parent.ctx.mpt)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed

proc getAccounts*(ctx: CoreDbCtxRef): CoreDbAccRef =
  ## Accounts column constructor, will defect on failure.
  ##
  ctx.setTrackNewApi CtxGetAccountsFn
  result =  ctx.parent.bless CoreDbAccRef()
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed

# ----------- accounts ---------------

proc fetch*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): CoreDbRc[CoreDbAccount] =
  ## Fetch the account data record for the particular account indexed by
  ## the key `accPath`.
  ##
  acc.setTrackNewApi AccFetchFn
  #result = acc.methods.fetchFn(acc, accPath)
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchAccountRecord, db.ctx.mpt, accPath)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError(base, $api, AccNotFound))
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc delete*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): CoreDbRc[void] =
  ## Delete the particular account indexed by the key `accPath`. This
  ## will also destroy an associated storage area.
  ##
  acc.setTrackNewApi AccDeleteFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(deleteAccountRecord, db.ctx.mpt, accPath)
    if rc.isOk:
      ok()
    elif rc.error == DelPathNotFound:
      # TODO: Would it be conseqient to just return `ok()` here?
      err(rc.error.toError(base, $api, AccNotFound))
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc clearStorage*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): CoreDbRc[void] =
  ## Delete all data slots from the storage area associated with the
  ## particular account indexed by the key `accPath`.
  ##
  acc.setTrackNewApi AccClearStorageFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(deleteStorageTree, db.ctx.mpt, accPath)
    if rc.isOk or rc.error in {DelStoRootMissing,DelStoAccMissing}:
      ok()
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc merge*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    accRec: CoreDbAccount;
      ): CoreDbRc[void] =
  ## Add or update the argument account data record `account`. Note that the
  ## `account` argument uniquely idendifies the particular account address.
  ##
  acc.setTrackNewApi AccMergeFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(mergeAccountRecord, db.ctx.mpt, accPath, accRec)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc hasPath*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(hasPathAccount, db.ctx.mpt, accPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc state*(acc: CoreDbAccRef; updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the accounts
  ## column (if available.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  acc.setTrackNewApi AccStateFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchAccountState, db.ctx.mpt, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, updateOK, result

# ------------ storage ---------------

proc slotFetch*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    slot: openArray[byte];
      ):  CoreDbRc[Blob] =
  ## Like `fetch()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotFetchFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchStorageData, db.ctx.mpt, accPath, slot)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError(base, $api, StoNotFound))
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr,
            slot=slot.toStr, result

proc slotDelete*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    slot: openArray[byte];
      ):  CoreDbRc[void] =
  ## Like `delete()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotDeleteFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(deleteStorageData, db.ctx.mpt, accPath, slot)
    if rc.isOk or rc.error == DelStoRootMissing:
      # The second `if` clause is insane but legit: A storage column was
      # announced for an account but no data have been added, yet.
      ok()
    elif rc.error == DelPathNotFound:
      err(rc.error.toError(base, $api, StoNotFound))
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr,
            slot=slot.toStr, result

proc slotHasPath*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    slot: openArray[byte];
      ):  CoreDbRc[bool] =
  ## Like `hasPath()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotHasPathFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(hasPathStorage, db.ctx.mpt, accPath, slot)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr,
            slot=slot.toStr, result

proc slotMerge*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    slot: openArray[byte];
    data: openArray[byte];
      ):  CoreDbRc[void] =
  ## Like `merge()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotMergeFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(mergeStorageData, db.ctx.mpt, accPath, slot, data)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr,
            slot=slot.toStr, result

proc slotState*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    updateOk = false;
      ):  CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the storage data
  ## column (if available) related to the account  indexed by the key
  ## `accPath`.`.
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  acc.setTrackNewApi AccSlotStateFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchStorageState, db.ctx.mpt, accPath, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, updateOk, result

proc slotStateEmpty*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ):  CoreDbRc[bool] =
  ## This function returns `true` if the storage data column is empty or
  ## missing.
  ##
  acc.setTrackNewApi AccSlotStateEmptyFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(hasStorageData, db.ctx.mpt, accPath)
    if rc.isOk:
      ok(not rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

proc slotStateEmptyOrVoid*(
    acc: CoreDbAccRef;
    accPath: Hash256;
      ): bool =
  ## Convenience wrapper, returns `true` where `slotStateEmpty()` would fail.
  acc.setTrackNewApi AccSlotStateEmptyOrVoidFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(hasStorageData, db.ctx.mpt, accPath)
    if rc.isOk:
      not rc.value
    else:
      true
  acc.ifTrackNewApi:
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, result

# ------------- other ----------------

proc recast*(
    acc: CoreDbAccRef;
    accPath: Hash256;
    accRec: CoreDbAccount;
    updateOk = false;
      ): CoreDbRc[Account] =
  ## Complete the argument `accRec` to the portable Ethereum representation
  ## of an account statement. This conversion may fail if the storage colState
  ## hash (see `slotState()` above) is currently unavailable.
  ##
  acc.setTrackNewApi EthAccRecastFn
  let
    db = acc.parent
    base = db.adbBase
  result = block:
    let rc = base.call(fetchStorageState, db.ctx.mpt, accPath, updateOk)
    if rc.isOk:
      ok Account(
        nonce:       accRec.nonce,
        balance:     accRec.balance,
        codeHash:    accRec.codeHash,
        storageRoot: rc.value)
    else:
      err(rc.error.toError(base, $api))
  acc.ifTrackNewApi:
    let slotState = if rc.isOk: rc.value.toStr else: "n/a"
    debug newApiTxt, api, elapsed, accPath=accPath.toStr, slotState, result

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc level*(db: CoreDbRef): int =
  ## Retrieve transaction level (zero if there is no pending transaction).
  ##
  db.setTrackNewApi BaseLevelFn
  result = db.methods.levelFn()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc persistent*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
      ): CoreDbRc[void] {.discardable.} =
  ## Variant of `persistent()` which stores a block number within the recovery
  ## journal record. This recoed will be addressable by the `blockNumber` (e.g.
  ##  for recovery.) The argument block number `blockNumber` must be greater
  ## than all previously stored block numbers.
  ##
  ## The function is intended to be used in a way so hat the argument block
  ## number `blockNumber` is associated with the state root to be recovered
  ## from a particular journal entry. This means that the correct block number
  ## will be the one of the state *before* a state change takes place. Using
  ## it that way, `pesistent()` must only be run after some blocks were fully
  ## executed.
  ##
  ## Example:
  ## ::
  ##   # Save block number for the current state
  ##   let stateBlockNumber = db.getCanonicalHead().blockNumber
  ##   ..
  ##   # Process blocks
  ##   ..
  ##   db.persistent(stateBlockNumber)
  ##
  db.setTrackNewApi BasePersistentFn
  result = db.methods.persistentFn blockNumber
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, blockNumber, result

proc newTransaction*(db: CoreDbRef): CoreDbTxRef =
  ## Constructor
  ##
  db.setTrackNewApi BaseNewTxFn
  result = db.methods.beginFn()
  db.ifTrackNewApi:
    debug newApiTxt, api, elapsed, newLevel=db.methods.levelFn()


proc level*(tx: CoreDbTxRef): int =
  ## Print positive transaction level for argument `tx`
  ##
  tx.setTrackNewApi TxLevelFn
  result = tx.methods.levelFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc commit*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.commitFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

proc rollback*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.rollbackFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

proc dispose*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.disposeFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

when false: # currently disabled
  proc newCapture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbRc[CoreDbCaptRef] =
    ## Trace constructor providing an overlay on top of the argument database
    ## `db`. This overlay provides a replacement database handle that can be
    ## retrieved via `db.recorder()` (which can in turn be ovelayed.) While
    ## running the overlay stores data in a log-table which can be retrieved
    ## via `db.logDb()`.
    ##
    ## Caveat:
    ##   The original database argument `db` should not be used while the tracer
    ##   is active (i.e. exists as overlay). The behaviour for this situation
    ##   is undefined and depends on the backend implementation of the tracer.
    ##
    db.setTrackNewApi BaseNewCaptureFn
    result = db.methods.newCaptureFn flags
    db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

  proc recorder*(cpt: CoreDbCaptRef): CoreDbRef =
    ## Getter, returns a tracer replacement handle to be used as new database.
    ## It records every action like fetch, store, hasKey, hasPath and delete.
    ## This descriptor can be superseded by a new overlay tracer (using
    ## `newCapture()`, again.)
    ##
    ## Caveat:
    ##   Unless the desriptor `cpt` referes to the top level overlay tracer, the
    ##   result is undefined and depends on the backend implementation of the
    ##   tracer.
    ##
    cpt.setTrackNewApi CptRecorderFn
    result = cpt.methods.recorderFn()
    cpt.ifTrackNewApi: debug newApiTxt, api, elapsed

  proc logDb*(cp: CoreDbCaptRef): TableRef[Blob,Blob] =
    ## Getter, returns the logger table for the overlay tracer database.
    ##
    ## Caveat:
    ##   Unless the desriptor `cpt` referes to the top level overlay tracer, the
    ##   result is undefined and depends on the backend implementation of the
    ##   tracer.
    ##
    cp.setTrackNewApi CptLogDbFn
    result = cp.methods.logDbFn()
    cp.ifTrackNewApi: debug newApiTxt, api, elapsed

  proc flags*(cp: CoreDbCaptRef):set[CoreDbCaptFlags] =
    ## Getter
    ##
    cp.setTrackNewApi CptFlagsFn
    result = cp.methods.getFlagsFn()
    cp.ifTrackNewApi: debug newApiTxt, api, elapsed, result

  proc forget*(cp: CoreDbCaptRef) =
    ## Explicitely stop recording the current tracer instance and reset to
    ## previous level.
    ##
    cp.setTrackNewApi CptForgetFn
    cp.methods.forgetFn()
    cp.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
