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
  chronicles,
  eth/common,
  "../.."/[constants, errors],
  ./base/[api_tracking, base_desc]

from ../aristo
  import EmptyBlob, PayloadRef, isValid

const
  EnableApiTracking = false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Tracking is enabled by setting `true` the flags
    ## `trackLegaApi` and/or `trackNewApi` in the `CoreDxTxRef` descriptor.

  EnableApiProfiling = true
    ## Enables functions profiling if `EnableApiTracking` is also set `true`.

  AutoValidateDescriptors = defined(release).not
    ## No validatinon needed for production suite.


export
  CoreDbAccount,
  CoreDbApiError,
  CoreDbCaptFlags,
  CoreDbColType,
  CoreDbColRef,
  CoreDbCtxRef,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbFnInx,
  CoreDbKvtBackendRef,
  CoreDbMptBackendRef,
  CoreDbPayloadRef,
  CoreDbPersistentTypes,
  CoreDbProfListRef,
  CoreDbRef,
  CoreDbType,
  CoreDxAccRef,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxRef,
  PayloadRef

const
  CoreDbEnableApiTracking* = EnableApiTracking
  CoreDbEnableApiProfiling* = EnableApiTracking and EnableApiProfiling

when AutoValidateDescriptors:
  import ./base/validate

# More settings
const
  logTxt = "CoreDb "
  newApiTxt = logTxt & "API"

# Annotation helpers
{.pragma:   apiRaise, gcsafe, raises: [CoreDbApiError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when EnableApiTracking:
  when EnableApiProfiling:
    {.warning: "*** Provided API profiling for CoreDB (disabled by default)".}
  else:
    {.warning: "*** Provided API logging for CoreDB (disabled by default)".}

  import
    std/times

  proc `$`[T](rc: CoreDbRc[T]): string = rc.toStr
  proc `$`(q: set[CoreDbCaptFlags]): string = q.toStr
  proc `$`(t: Duration): string = t.toStr
  proc `$`(e: EthAddress): string = e.toStr
  proc `$`(v: CoreDbColRef): string = v.toStr
  proc `$`(h: Hash256): string = h.toStr

template setTrackNewApi(
    w: CoreDxApiTrackRef;
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
    w: CoreDxApiTrackRef;
    s: static[CoreDbFnInx];
      ) =
  w.setTrackNewApi(s):
    discard

template ifTrackNewApi*(w: CoreDxApiTrackRef; code: untyped) =
  when EnableApiTracking:
    w.endNewApiIf:
      code

# ---------

func toCoreDxPhkRef(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## MPT => pre-hashed MPT (aka PHK)
  result = CoreDxPhkRef(
    toMpt: mpt,
    methods: mpt.methods)

  result.methods.fetchFn =
    proc(k: openArray[byte]): CoreDbRc[Blob] =
      mpt.methods.fetchFn(k.keccakHash.data)

  result.methods.deleteFn =
    proc(k: openArray[byte]): CoreDbRc[void] =
      mpt.methods.deleteFn(k.keccakHash.data)

  result.methods.mergeFn =
    proc(k:openArray[byte]; v: openArray[byte]): CoreDbRc[void] =
      mpt.methods.mergeFn(k.keccakHash.data, v)

  result.methods.hasPathFn =
    proc(k: openArray[byte]): CoreDbRc[bool] =
      mpt.methods.hasPathFn(k.keccakHash.data)

  when AutoValidateDescriptors:
    result.validate


func parent(phk: CoreDxPhkRef): CoreDbRef =
  phk.toMpt.parent

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

proc bless*(db: CoreDbRef; col: CoreDbColRef): CoreDbColRef =
  ## Complete sub-module descriptor, fill in `parent` and actvate it.
  col.parent = db
  col.ready = true
  when AutoValidateDescriptors:
    col.validate
  col

proc bless*(db: CoreDbRef; kvt: CoreDxKvtRef): CoreDxKvtRef =
  ## Complete sub-module descriptor, fill in `parent`.
  kvt.parent = db
  when AutoValidateDescriptors:
    kvt.validate
  kvt

proc bless*[T: CoreDxKvtRef |
               CoreDbCtxRef | CoreDxMptRef | CoreDxPhkRef | CoreDxAccRef |
               CoreDxTxRef  | CoreDxCaptRef |
               CoreDbKvtBackendRef | CoreDbMptBackendRef](
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

proc prettyText*(col: CoreDbColRef): string =
  ## Pretty print argument object (for tracking use `$$()`)
  if col.isNil or not col.ready: "$ø" else: col.toStr()

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

proc parent*[T: CoreDxKvtRef |
                CoreDbColRef |
                CoreDbCtxRef | CoreDxMptRef | CoreDxPhkRef | CoreDxAccRef |
                CoreDxTxRef |
                CoreDxCaptRef |
                CoreDbErrorRef](
    child: T): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = child.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxMptRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  dsc.setTrackNewApi AnyBackendFn
  result = dsc.methods.backendFn()
  dsc.ifTrackNewApi: debug newApiTxt, api, elapsed

proc finish*(db: CoreDbRef; flush = false) =
  ## Database destructor. If the argument `flush` is set `false`, the database
  ## is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  ##
  db.setTrackNewApi BaseFinishFn
  db.methods.destroyFn flush
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

proc newKvt*(db: CoreDbRef): CoreDxKvtRef =
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

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtGetFn
  result = kvt.methods.getFn key
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function sort of mimics the behaviour of the legacy database
  ## returning an empty `Blob` if the argument `key` is not found on the
  ## database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  result = kvt.methods.getFn key
  if result.isErr and result.error.error == KvtNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc del*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  result = kvt.methods.delFn key
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDxKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  result = kvt.methods.putFn(key, val)
  kvt.ifTrackNewApi:
    debug newApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr, result

proc hasKey*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  kvt.setTrackNewApi KvtHasKeyFn
  result = kvt.methods.hasKeyFn key
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

proc ctxFromTx*(
    db: CoreDbRef;
    colState: Hash256;
    colType = CtAccounts;
      ): CoreDbRc[CoreDbCtxRef] =
  ## Create new context derived from matching transaction of the currently
  ## active column context. For the legacy backend, this function always
  ## returns the currently active context (i.e. the same as `db.ctx()`.)
  ##
  db.setTrackNewApi BaseNewCtxFromTxFn
  result = db.methods.newCtxFromTxFn(colState, colType)
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

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
  ctx.methods.forgetFn()
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree sub-trie abstaction management
# ------------------------------------------------------------------------------

proc newColumn*(
    ctx: CoreDbCtxRef;
    colType: CoreDbColType;
    colState: Hash256;
    address = Opt.none(EthAddress);
      ): CoreDbRc[CoreDbColRef] =
  ## Retrieve a new column descriptor.
  ##
  ## The database is can be viewed as a matrix of rows and columns, potenially
  ## with values at their intersection. A row is identified by a lookup key
  ## and a column is identified by a state hash.
  ##
  ## Additionally, any column has a column type attribute given as `colType`
  ## argument. Only storage columns also have an address attribute which must
  ## be passed as argument `address` when the `colType` argument is `CtStorage`.
  ##
  ## If the state hash argument `colState` is passed as `EMPTY_ROOT_HASH`, this
  ## function always succeeds. The result is the equivalent of a potential
  ## column be incarnated later. If the column type is different from
  ## `CtStorage` and `CtAccounts`, then the returned column descriptor will be
  ## flagged to reset all column data when incarnated as MPT (see `newMpt()`.).
  ##
  ## Otherwise, the function will fail unless a column with the corresponding
  ## argument `colState` identifier exists and can be found on the database.
  ## Note that on a single state database like `Aristo`, the requested column
  ## might exist but is buried in some history journal (which needs an extra
  ## effort to unwrap.)
  ##
  ## This function is intended to open a column on the database as in:
  ## ::
  ##   proc openAccountLedger(db: CoreDbRef, colState: Hash256): CoreDxMptRef =
  ##     let col = db.ctx.newColumn(CtAccounts, colState).valueOr:
  ##       # some error handling
  ##       return
  ##     db.getAcc col
  ##
  ctx.setTrackNewApi CtxNewColFn
  result = ctx.methods.newColFn(colType, colState, address)
  ctx.ifTrackNewApi:
    debug newApiTxt, api, elapsed, colType, colState, address, result

proc newColumn*(
    ctx: CoreDbCtxRef;
    colState: Hash256;
    address: EthAddress;
      ): CoreDbRc[CoreDbColRef] =
  ## Shortcut for `ctx.newColumn(CtStorage,colState,some(address))`.
  ##
  ctx.setTrackNewApi CtxNewColFn
  result = ctx.methods.newColFn(CtStorage, colState, Opt.some(address))
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed, colState, address, result

proc newColumn*(
    ctx: CoreDbCtxRef;
    address: EthAddress;
      ): CoreDbColRef =
  ## Shortcut for `ctx.newColumn(EMPTY_ROOT_HASH,address).value`. The function
  ## will throw an exception on error. So the result will always be a valid
  ## descriptor.
  ##
  ctx.setTrackNewApi CtxNewColFn
  result = ctx.methods.newColFn(
      CtStorage, EMPTY_ROOT_HASH, Opt.some(address)).valueOr:
    raiseAssert error.prettyText()
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result


proc `$$`*(col: CoreDbColRef): string =
  ## Pretty print the column descriptor. Note that this directive may have side
  ## effects as it calls a backend function.
  ##
  #col.setTrackNewApi ColPrintFn
  result = col.prettyText()
  #col.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc state*(col: CoreDbColRef): CoreDbRc[Hash256] =
  ## Getter (well, sort of). It retrieves the column state hash for the
  ## argument `col` descriptor. The function might fail unless the current
  ## state is available (e.g. on `Aristo`.)
  ##
  ## The value `EMPTY_ROOT_HASH` is returned on the void `col` descriptor
  ## argument `CoreDbColRef(nil)`.
  ##
  col.setTrackNewApi BaseColStateFn
  result = block:
    if not col.isNil and col.ready:
      col.parent.methods.colStateFn col
    else:
      ok EMPTY_ROOT_HASH
  # Note: tracker will be silent if `vid` is NIL
  col.ifTrackNewApi: debug newApiTxt, api, elapsed, col, result

proc stateOrVoid*(col: CoreDbColRef): Hash256 =
  ## Convenience wrapper, returns `EMPTY_ROOT_HASH` where `state()` would fail.
  col.state.valueOr: EMPTY_ROOT_HASH

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc getMpt*(
    ctx: CoreDbCtxRef;
    col: CoreDbColRef;
      ): CoreDbRc[CoreDxMptRef] =
  ## Get an MPT sub-trie view.
  ##
  ## If the `col` argument descriptor was created for an `EMPTY_ROOT_HASH`
  ## column state of type different form `CtStorage` or `CtAccounts`, all
  ## column will be flushed. There is no need to hold the `col` argument for
  ## later use. It can always be rerieved for this particular MPT using the
  ## function `getColumn()`.
  ##
  ctx.setTrackNewApi CtxGetMptFn
  result = ctx.methods.getMptFn col
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed, col, result

proc getMpt*(
    ctx: CoreDbCtxRef;
    colType: CoreDbColType;
    address = Opt.none(EthAddress);
      ): CoreDxMptRef =
  ## Shortcut for `getMpt(col)` where the `col` argument is
  ## `db.getColumn(colType,EMPTY_ROOT_HASH).value`. This function will always
  ## return a non-nil descriptor or throw an exception.
  ##
  ctx.setTrackNewApi CtxGetMptFn
  let col = ctx.methods.newColFn(colType, EMPTY_ROOT_HASH, address).value
  result = ctx.methods.getMptFn(col).valueOr:
    raiseAssert error.prettyText()
  ctx.ifTrackNewApi: debug newApiTxt, api, colType, elapsed


proc getMpt*(acc: CoreDxAccRef): CoreDxMptRef =
  ## Variant of `getMpt()`, will defect on failure.
  ##
  ## The needed sub-trie information is taken/implied from the current `acc`
  ## argument.
  ##
  acc.setTrackNewApi AccToMptFn
  result = acc.methods.getMptFn().valueOr:
    raiseAssert error.prettyText()
  acc.ifTrackNewApi:
    let colState = result.methods.getColFn()
    debug newApiTxt, api, elapsed, colState


proc getAcc*(
    ctx: CoreDbCtxRef;
    col: CoreDbColRef;
      ): CoreDbRc[CoreDxAccRef] =
  ## Accounts trie constructor, will defect on failure.
  ##
  ## Example:
  ## ::
  ##   let col = db.getColumn(CtAccounts,<some-hash>).valueOr:
  ##     ... # No node available with <some-hash>
  ##     return
  ##
  ##   let acc = db.getAccMpt(col)
  ##     ... # Was not the state root for the accounts column
  ##     return
  ##
  ## This function works similar to `getMpt()` for handling accounts. Although
  ## one can emulate this function by means of `getMpt(..).toPhk()`, it is
  ## recommended using `CoreDxAccRef` methods for accounts.
  ##
  ctx.setTrackNewApi CtxGetAccFn
  result = ctx.methods.getAccFn col
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed, col, result

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument column `phk` by the non pre-hashed *MPT*.
  ##
  phk.setTrackNewApi PhkToMptFn
  result = phk.toMpt
  phk.ifTrackNewApi:
    let col = result.methods.getColFn()
    debug newApiTxt, api, elapsed, col

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ##
  mpt.setTrackNewApi MptToPhkFn
  result = mpt.toCoreDxPhkRef
  mpt.ifTrackNewApi:
    let col = result.methods.getColFn()
    debug newApiTxt, api, elapsed, col

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc getColumn*(acc: CoreDxAccRef): CoreDbColRef =
  ## Getter, result is not `nil`
  ##
  acc.setTrackNewApi AccGetColFn
  result = acc.methods.getColFn()
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc getColumn*(mpt: CoreDxMptRef): CoreDbColRef =
  ## Variant of `getColumn()`
  ##
  mpt.setTrackNewApi MptGetColFn
  result = mpt.methods.getColFn()
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc getColumn*(phk: CoreDxPhkRef): CoreDbColRef =
  ## Variant of `getColumn()`
  ##
  phk.setTrackNewApi PhkGetColFn
  result = phk.methods.getColFn()
  phk.ifTrackNewApi: debug newApiTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `mpt`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  result = mpt.methods.fetchFn key
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc fetch*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetch()"
  phk.setTrackNewApi PhkFetchFn
  result = phk.methods.fetchFn key
  phk.ifTrackNewApi:
    let col = phk.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result


proc fetchOrEmpty*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  result = mpt.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc fetchOrEmpty*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetchOrEmpty()`
  phk.setTrackNewApi PhkFetchOrEmptyFn
  result = phk.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  phk.ifTrackNewApi:
    let col = phk.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result


proc delete*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  result = mpt.methods.deleteFn key
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc delete*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[void] =
  phk.setTrackNewApi PhkDeleteFn
  result = phk.methods.deleteFn key
  phk.ifTrackNewApi:
    let col = phk.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result


proc merge*(
    mpt: CoreDxMptRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  result = mpt.methods.mergeFn(key, val)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, val=val.toLenStr, result

proc merge*(
    phk: CoreDxPhkRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  phk.setTrackNewApi PhkMergeFn
  result = phk.methods.mergeFn(key, val)
  phk.ifTrackNewApi:
    let col = phk.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, val=val.toLenStr, result


proc hasPath*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  result = mpt.methods.hasPathFn key
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc hasPath*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Variant of `hasPath()`
  phk.setTrackNewApi PhkHasPathFn
  result = phk.methods.hasPathFn key
  phk.ifTrackNewApi:
    let col = phk.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `acc`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = acc.methods.fetchFn address
  acc.ifTrackNewApi:
    let storage = if result.isErr: "n/a" else: result.value.storage.prettyText()
    debug newApiTxt, api, elapsed, address, storage, result


proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  acc.setTrackNewApi AccDeleteFn
  result = acc.methods.deleteFn address
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result

proc stoFlush*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  ## Recursively delete all data elements from the storage trie associated to
  ## the account identified by the argument `address`. After successful run,
  ## the storage trie will be empty.
  ##
  ## Caveat:
  ##   This function has no effect on the legacy backend so it must not be
  ##   relied upon in general. On the legacy backend, storage tries might be
  ##   shared by several accounts whereas they are unique on the `Aristo`
  ##   backend.
  ##
  acc.setTrackNewApi AccStoFlushFn
  result = acc.methods.stoFlushFn address
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result


proc merge*(
    acc: CoreDxAccRef;
    account: CoreDbAccount;
      ): CoreDbRc[void] =
  acc.setTrackNewApi AccMergeFn
  result = acc.methods.mergeFn account
  acc.ifTrackNewApi:
    let address = account.address
    debug newApiTxt, api, elapsed, address, result


proc hasPath*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  result = acc.methods.hasPathFn address
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result


proc recast*(statement: CoreDbAccount): CoreDbRc[Account] =
  ## Convert the argument `statement` to the portable Ethereum representation
  ## of an account statement. This conversion may fail if the storage colState
  ## hash (see `hash()` above) is currently unavailable.
  ##
  ## Note:
  ##   With the legacy backend, this function always succeeds.
  ##
  let storage = statement.storage
  storage.setTrackNewApi EthAccRecastFn
  let rc =
    if storage.isNil or not storage.ready: CoreDbRc[Hash256].ok(EMPTY_ROOT_HASH)
    else: storage.parent.methods.colStateFn storage
  result =
    if rc.isOk:
      ok Account(
        nonce:       statement.nonce,
        balance:     statement.balance,
        codeHash:    statement.codeHash,
        storageRoot: rc.value)
    else:
      err(rc.error)
  storage.ifTrackNewApi: debug newApiTxt, api, elapsed, storage, result

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
      ): CoreDbRc[void] =
  ## For the legacy database, this function has no effect and succeeds always.
  ## It will nevertheless return a discardable error if there is a pending
  ## transaction (i.e. `db.level() == 0`.)
  ##
  ## Otherwise, cached data from the `Kvt`, `Mpt`, and `Acc` descriptors are
  ## stored on the persistent database (if any). This requires that that there
  ## is no transaction pending.
  ##
  db.setTrackNewApi BasePersistentFn
  result = db.methods.persistentFn Opt.none(BlockNumber)
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
  result = db.methods.persistentFn Opt.some(blockNumber)
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, blockNumber, result

proc newTransaction*(db: CoreDbRef): CoreDxTxRef =
  ## Constructor
  ##
  db.setTrackNewApi BaseNewTxFn
  result = db.methods.beginFn()
  db.ifTrackNewApi:
    debug newApiTxt, api, elapsed, newLevel=db.methods.levelFn()


proc level*(tx: CoreDxTxRef): int =
  ## Print positive transaction level for argument `tx`
  ##
  tx.setTrackNewApi TxLevelFn
  result = tx.methods.levelFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc commit*(tx: CoreDxTxRef) =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.commitFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

proc rollback*(tx: CoreDxTxRef) =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.rollbackFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

proc dispose*(tx: CoreDxTxRef) =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  tx.methods.disposeFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc newCapture*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbRc[CoreDxCaptRef] =
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

proc recorder*(cpt: CoreDxCaptRef): CoreDbRef =
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

proc logDb*(cp: CoreDxCaptRef): TableRef[Blob,Blob] =
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

proc flags*(cp: CoreDxCaptRef):set[CoreDbCaptFlags] =
  ## Getter
  ##
  cp.setTrackNewApi CptFlagsFn
  result = cp.methods.getFlagsFn()
  cp.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc forget*(cp: CoreDxCaptRef) =
  ## Explicitely stop recording the current tracer instance and reset to
  ## previous level.
  ##
  cp.setTrackNewApi CptForgetFn
  cp.methods.forgetFn()
  cp.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
