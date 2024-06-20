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
  ./base/[api_tracking, base_desc]

from ../aristo
  import EmptyBlob, PayloadRef, isValid

const
  EnableApiTracking = false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Tracking is enabled by setting `true` the flags
    ## `trackLegaApi` and/or `trackNewApi` in the `CoreDbTxRef` descriptor.

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
  CoreDbAccRef,
  CoreDbCaptRef,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbTxRef,
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

proc bless*(db: CoreDbRef; kvt: CoreDbKvtRef): CoreDbKvtRef =
  ## Complete sub-module descriptor, fill in `parent`.
  kvt.parent = db
  when AutoValidateDescriptors:
    kvt.validate
  kvt

proc bless*[T: CoreDbKvtRef |
               CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef |
               CoreDbTxRef  | CoreDbCaptRef |
               CoreDbKvtBackendRef | CoreDbMptBackendRef | CoreDbAccBackendRef] (
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

proc parent*[T: CoreDbKvtRef |
                CoreDbColRef |
                CoreDbCtxRef | CoreDbMptRef | CoreDbAccRef |
                CoreDbTxRef |
                CoreDbCaptRef |
                CoreDbErrorRef](
    child: T): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = child.parent

proc backend*(dsc: CoreDbKvtRef | CoreDbMptRef | CoreDbAccRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  dsc.setTrackNewApi AnyBackendFn
  result = dsc.methods.backendFn()
  dsc.ifTrackNewApi: debug newApiTxt, api, elapsed

proc backend*(mpt: CoreDbMptRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  ##
  mpt.setTrackNewApi AnyBackendFn
  result = mpt.methods.backendFn(mpt)
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed

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

proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtGetFn
  result = kvt.methods.getFn key
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc len*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[int] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtLenFn
  result = kvt.methods.lenFn key
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function sort of mimics the behaviour of the legacy database
  ## returning an empty `Blob` if the argument `key` is not found on the
  ## database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  result = kvt.methods.getFn key
  if result.isErr and result.error.error == KvtNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  result = kvt.methods.delFn key
  kvt.ifTrackNewApi: debug newApiTxt, api, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDbKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  result = kvt.methods.putFn(key, val)
  kvt.ifTrackNewApi:
    debug newApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr, result

proc hasKey*(kvt: CoreDbKvtRef; key: openArray[byte]): CoreDbRc[bool] =
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

#proc ctxFromTx*(
#    db: CoreDbRef;
#    colState: Hash256;
#    colType = CtAccounts;
#      ): CoreDbRc[CoreDbCtxRef] =
#  ## Create new context derived from matching transaction of the currently
#  ## active column context. For the legacy backend, this function always
#  ## returns the currently active context (i.e. the same as `db.ctx()`.)
#  ##
#  db.setTrackNewApi BaseNewCtxFromTxFn
#  result = db.methods.newCtxFromTxFn(colState, colType)
#  db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

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
  ctx.methods.forgetFn(ctx)
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree sub-trie abstaction management
# ------------------------------------------------------------------------------

proc `$$`*(col: CoreDbColRef): string =
  ## Pretty print the column descriptor. Note that this directive may have side
  ## effects as it calls a backend function.
  ##
  #col.setTrackNewApi ColPrintFn
  result = col.prettyText()
  #col.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc stateEmpty*(col: CoreDbColRef): CoreDbRc[bool] =
  ## Getter (well, sort of). It retrieves the column state hash for the
  ## argument `col` descriptor. The function might fail unless the current
  ## state is available (e.g. on `Aristo`.)
  ##
  ## The value `EMPTY_ROOT_HASH` is returned on the void `col` descriptor
  ## argument `CoreDbColRef(nil)`.
  ##
  col.setTrackNewApi BaseColStateEmptyFn
  result = block:
    if not col.isNil and col.ready:
      col.parent.methods.colStateEmptyFn col
    else:
      ok true
  # Note: tracker will be silent if `vid` is NIL
  col.ifTrackNewApi: debug newApiTxt, api, elapsed, col, result

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

proc stateEmptyOrVoid*(col: CoreDbColRef): bool =
  ## Convenience wrapper, returns `true` where `stateEmpty()` would fail.
  col.stateEmpty.valueOr: true

# ------------------------------------------------------------------------------
# Public functions for generic columns
# ------------------------------------------------------------------------------

proc getColumn*(
    ctx: CoreDbCtxRef;
    colType: CoreDbColType;
    clearData = false;
      ): CoreDbMptRef =
  ## ...
  ##
  ctx.setTrackNewApi CtxGetColumnFn
  result = ctx.methods.getColumnFn(ctx, colType, clearData)
  ctx.ifTrackNewApi: debug newApiTxt, api, colType, clearData, elapsed

proc fetch*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `mpt`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  result = mpt.methods.fetchFn(mpt, key)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn(mpt)
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc fetchOrEmpty*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  result = mpt.methods.fetchFn(mpt, key)
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn(mpt)
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc delete*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  result = mpt.methods.deleteFn(mpt, key)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn()
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc merge*(
    mpt: CoreDbMptRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  result = mpt.methods.mergeFn(mpt, key, val)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn(mpt)
    debug newApiTxt, api, elapsed, col, key=key.toStr, val=val.toLenStr, result

proc hasPath*(mpt: CoreDbMptRef; key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  result = mpt.methods.hasPathFn(mpt, key)
  mpt.ifTrackNewApi:
    let col = mpt.methods.getColFn(mpt)
    debug newApiTxt, api, elapsed, col, key=key.toStr, result

proc state*(mpt: CoreDbMptRef; updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the argument
  ## database column (if acvailable.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  mpt.setTrackNewApi MptStateFn
  result = mpt.methods.stateFn(mpt, updateOk)
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, updateOK, result

# ------------------------------------------------------------------------------
# Public methods for accounts
# ------------------------------------------------------------------------------

proc getAccounts*(ctx: CoreDbCtxRef): CoreDbAccRef =
  ## Accounts column constructor, will defect on failure.
  ##
  ctx.setTrackNewApi CtxGetAccountsFn
  result = ctx.methods.getAccountsFn(ctx)
  ctx.ifTrackNewApi: debug newApiTxt, api, elapsed, col, result

# ----------- accounts ---------------

proc fetch*(acc: CoreDbAccRef; eAddr: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch the account data record for the particular account indexed by
  ## the address `eAddr`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = acc.methods.fetchFn(acc, eAddr)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc delete*(acc: CoreDbAccRef; eAddr: EthAddress): CoreDbRc[void] =
  ## Delete the particular account indexed by the address `eAddr`. This
  ## will also destroy an associated storage area.
  ##
  acc.setTrackNewApi AccDeleteFn
  result = acc.methods.deleteFn(acc, eAddr)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result

proc clearStorage*(acc: CoreDbAccRef; eAddr: EthAddress): CoreDbRc[void] =
  ## Delete all data slots from the storage area associated with the
  ## particular account indexed by the address `eAddr`.
  ##
  acc.setTrackNewApi AccClearStorageFn
  result = acc.methods.clearStorageFn(acc, eAddr)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc merge*(acc: CoreDbAccRef; account: CoreDbAccount): CoreDbRc[void] =
  ## Add or update the argument account data record `account`. Note that the
  ## `account` argument uniquely idendifies the particular account address.
  ##
  acc.setTrackNewApi AccMergeFn
  result = acc.methods.mergeFn(acc, account)
  acc.ifTrackNewApi:
    let eAddr = account.address
    debug newApiTxt, api, elapsed, eAddr, result

proc hasPath*(acc: CoreDbAccRef; eAddr: EthAddress): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  result = acc.methods.hasPathFn(acc, eAddr)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc state*(acc: CoreDbAccRef; updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the accounts
  ## column (if acvailable.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  acc.setTrackNewApi AccStateFn
  result = acc.methods.stateFn(acc, updateOk)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, updateOK, result

# ------------ storage ---------------

proc slotFetch*(
    acc: CoreDbAccRef;
    eAddr: EthAddress;
    slot: openArray[byte];
      ):  CoreDbRc[Blob] =
  acc.setTrackNewApi AccSlotFetchFn
  result = acc.methods.slotFetchFn(acc, eAddr, slot)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc slotDelete*(
    acc: CoreDbAccRef;
    eAddr: EthAddress;
    slot: openArray[byte];
      ):  CoreDbRc[void] =
  acc.setTrackNewApi AccSlotDeleteFn
  result = acc.methods.slotDeleteFn(acc, eAddr, slot)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc slotHasPath*(
    acc: CoreDbAccRef;
    eAddr: EthAddress;
    slot: openArray[byte];
      ):  CoreDbRc[bool] =
  acc.setTrackNewApi AccSlotHasPathFn
  result = acc.methods.slotHasPathFn(acc, eAddr, slot)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc slotMerge*(
    acc: CoreDbAccRef;
    eAddr: EthAddress;
    slot: openArray[byte];
    data: openArray[byte];
      ):  CoreDbRc[void] =
  acc.setTrackNewApi AccSlotMergeFn
  result = acc.methods.slotMergeFn(acc, eAddr, slot, data)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, result

proc slotState*(
    acc: CoreDbAccRef;
    eAddr: EthAddress;
    updateOk = false;
      ):  CoreDbRc[Hash256] =
  acc.setTrackNewApi AccSlotStateFn
  result = acc.methods.slotStateFn(acc, eAddr, updateOk)
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, eAddr, updateOk, result

# ------------- other ----------------

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
