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
  "../.."/[constants, errors],
  ".."/[kvt, aristo],
  ./base/[api_tracking, base_config, base_desc, base_helpers]

export
  CoreDbAccRef,
  CoreDbAccount,
  CoreDbApiError,
  #CoreDbCaptFlags,
  #CoreDbCaptRef,
  CoreDbCtxRef,
  CoreDbErrorCode,
  CoreDbError,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbPersistentTypes,
  CoreDbRef,
  CoreDbTxRef,
  CoreDbType

when CoreDbEnableApiTracking:
  {.warning: "*** Provided API logging for CoreDB (disabled by default)".}
  import chronicles
  logScope:
    topics = "core_db"
  const logTxt = "API"

when CoreDbEnableProfiling:
  {.warning: "*** Enabled profiling for CoreDB (also tracer API available)".}
  export CoreDbFnInx, CoreDbProfListRef

when CoreDbEnableApiJumpTable:
  discard
else:
  import
    ../aristo/[aristo_delete, aristo_desc, aristo_fetch, aristo_merge, aristo_tx],
    ../kvt/[kvt_desc, kvt_utils, kvt_tx]

# ------------------------------------------------------------------------------
# Public context constructors and administration
# ------------------------------------------------------------------------------

proc ctx*(db: CoreDbRef): CoreDbCtxRef =
  ## Get the defauly context. This is a base descriptor which provides the
  ## KVT, MPT, the accounts descriptors as well as the transaction descriptor.
  ## They are kept all in sync, i.e. `persistent()` will store exactly this
  ## context.
  ##
  db.defCtx

proc swapCtx*(db: CoreDbRef, ctx: CoreDbCtxRef): CoreDbCtxRef =
  ## Activate argument context `ctx` as default and return the previously
  ## active context. This function goes typically together with `forget()`. A
  ## valid scenario might look like
  ## ::
  ##   proc doSomething(db: CoreDbRef; ctx: CoreDbCtxRef) =
  ##     let saved = db.swapCtx ctx
  ##     defer: db.swapCtx(saved).forget()
  ##     ...
  ##
  doAssert not ctx.isNil
  db.setTrackNewApi BaseSwapCtxFn
  result = db.defCtx

  # Set read-write access and install
  CoreDbAccRef(ctx).call(reCentre, db.ctx.mpt).isOkOr:
    raiseAssert $api & " failed: " & $error
  CoreDbKvtRef(ctx).call(reCentre, db.ctx.kvt).isOkOr:
    raiseAssert $api & " failed: " & $error
  db.defCtx = ctx
  db.ifTrackNewApi:
    debug logTxt, api, elapsed

proc forget*(ctx: CoreDbCtxRef) =
  ## Dispose `ctx` argument context and related columns created with this
  ## context. This function fails if `ctx` is the default context.
  ##
  ctx.setTrackNewApi CtxForgetFn
  CoreDbAccRef(ctx).call(forget, ctx.mpt).isOkOr:
    raiseAssert $api & ": " & $error
  CoreDbKvtRef(ctx).call(forget, ctx.kvt).isOkOr:
    raiseAssert $api & ": " & $error
  ctx.ifTrackNewApi:
    debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc finish*(db: CoreDbRef, eradicate = false) =
  ## Database destructor. If the argument `eradicate` is set `false`, the
  ## database is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  ##
  db.setTrackNewApi BaseFinishFn
  CoreDbKvtRef(db.ctx).call(finish, db.ctx.kvt, eradicate)
  CoreDbAccRef(db.ctx).call(finish, db.ctx.mpt, eradicate)
  db.ifTrackNewApi:
    debug logTxt, api, elapsed

proc `$$`*(e: CoreDbError): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  ##
  e.toStr()

proc persistent*(
    db: CoreDbRef, blockNumber: BlockNumber
): CoreDbRc[void] {.discardable.} =
  ## This function stored cached data from the default context (see `ctx()`
  ## below) to the persistent database.
  ##
  ## It also stores the argument block number `blockNumber` as a state record
  ## which can be retrieved via `stateBlockNumber()`.
  ##
  db.setTrackNewApi BasePersistentFn
  block body:
    block:
      let rc = CoreDbKvtRef(db.ctx).call(persist, db.ctx.kvt)
      if rc.isOk or rc.error == TxPersistDelayed:
        # The latter clause is OK: Piggybacking on `Aristo` backend
        discard
      elif CoreDbKvtRef(db.ctx).call(level, db.ctx.kvt) != 0:
        result = err(rc.error.toError($api, TxPending))
        break body
      else:
        result = err(rc.error.toError $api)
        break body
    block:
      let rc = CoreDbAccRef(db.ctx).call(persist, db.ctx.mpt, blockNumber)
      if rc.isOk:
        discard
      elif CoreDbAccRef(db.ctx).call(level, db.ctx.mpt) != 0:
        result = err(rc.error.toError($api, TxPending))
        break body
      else:
        result = err(rc.error.toError $api)
        break body
    result = ok()
  db.ifTrackNewApi:
    debug logTxt, api, elapsed, blockNumber, result

proc stateBlockNumber*(db: CoreDbRef): BlockNumber =
  ## Rhis function returns the block number stored with the latest `persist()`
  ## directive.
  ##
  db.setTrackNewApi BaseStateBlockNumberFn
  result = block:
    let rc = CoreDbAccRef(db.ctx).call(fetchLastSavedState, db.ctx.mpt)
    if rc.isOk: rc.value.serial.BlockNumber else: 0u64
  db.ifTrackNewApi:
    debug logTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc getKvt*(ctx: CoreDbCtxRef): CoreDbKvtRef =
  ## This function retrieves the common base object shared with other KVT
  ## descriptors. Any changes are immediately visible to subscribers.
  ## On destruction (when the constructed object gets out of scope), changes
  ## are not saved to the backend database but are still cached and available.
  ##
  CoreDbKvtRef(ctx)

# ----------- KVT ---------------

proc get*(kvt: CoreDbKvtRef, key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtGetFn
  result = block:
    let rc = kvt.call(get, kvt.kvt, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError($api, KvtNotFound))
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc getOrEmpty*(kvt: CoreDbKvtRef, key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `get()` returning an empty `Blob` if the key is not found
  ## on the database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  result = block:
    let rc = kvt.call(get, kvt.kvt, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      CoreDbRc[Blob].ok(EmptyBlob)
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc len*(kvt: CoreDbKvtRef, key: openArray[byte]): CoreDbRc[int] =
  ## This function returns the size of the value associated with `key`.
  kvt.setTrackNewApi KvtLenFn
  result = block:
    let rc = kvt.call(len, kvt.kvt, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError($api, KvtNotFound))
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc del*(kvt: CoreDbKvtRef, key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  result = block:
    let rc = kvt.call(del, kvt.kvt, key)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc put*(
    kvt: CoreDbKvtRef, key: openArray[byte], val: openArray[byte]
): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  result = block:
    let rc = kvt.call(put, kvt.kvt, key, val)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, val = val.toLenStr, result

proc hasKey*(kvt: CoreDbKvtRef, key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  kvt.setTrackNewApi KvtHasKeyFn
  result = block:
    let rc = kvt.call(hasKey, kvt.kvt, key)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

# ------------------------------------------------------------------------------
# Public functions for generic columns
# ------------------------------------------------------------------------------

proc getGeneric*(ctx: CoreDbCtxRef, clearData = false): CoreDbMptRef =
  ## Get a generic MPT, viewed as column
  ##
  ctx.setTrackNewApi CtxGetGenericFn
  result = CoreDbMptRef(ctx)
  if clearData:
    result.call(deleteGenericTree, ctx.mpt, CoreDbVidGeneric).isOkOr:
      raiseAssert $api & ": " & $error
  ctx.ifTrackNewApi:
    debug logTxt, api, clearData, elapsed

# ----------- generic MPT ---------------

proc fetch*(mpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `mpt`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  result = block:
    let rc = mpt.call(fetchGenericData, mpt.mpt, CoreDbVidGeneric, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError($api, MptNotFound))
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc fetchOrEmpty*(mpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  result = block:
    let rc = mpt.call(fetchGenericData, mpt.mpt, CoreDbVidGeneric, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      CoreDbRc[Blob].ok(EmptyBlob)
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc delete*(mpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  result = block:
    let rc = mpt.call(deleteGenericData, mpt.mpt, CoreDbVidGeneric, key)
    if rc.isOk:
      ok()
    elif rc.error == DelPathNotFound:
      err(rc.error.toError($api, MptNotFound))
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc merge*(
    mpt: CoreDbMptRef, key: openArray[byte], val: openArray[byte]
): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  result = block:
    let rc = mpt.call(mergeGenericData, mpt.mpt, CoreDbVidGeneric, key, val)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, val = val.toLenStr, result

proc hasPath*(mpt: CoreDbMptRef, key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  result = block:
    let rc = mpt.call(hasPathGeneric, mpt.mpt, CoreDbVidGeneric, key)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, key = key.toStr, result

proc state*(mpt: CoreDbMptRef, updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the argument
  ## database column (if acvailable.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  mpt.setTrackNewApi MptStateFn
  result = block:
    let rc = mpt.call(fetchGenericState, mpt.mpt, CoreDbVidGeneric, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  mpt.ifTrackNewApi:
    debug logTxt, api, elapsed, updateOK, result

# ------------------------------------------------------------------------------
# Public methods for accounts
# ------------------------------------------------------------------------------

proc getAccounts*(ctx: CoreDbCtxRef): CoreDbAccRef =
  ## Accounts column constructor, will defect on failure.
  ##
  ctx.setTrackNewApi CtxGetAccountsFn
  result = CoreDbAccRef(ctx)
  ctx.ifTrackNewApi:
    debug logTxt, api, elapsed

# ----------- accounts ---------------

proc fetch*(acc: CoreDbAccRef, accPath: Hash256): CoreDbRc[CoreDbAccount] =
  ## Fetch the account data record for the particular account indexed by
  ## the key `accPath`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = block:
    let rc = acc.call(fetchAccountRecord, acc.mpt, accPath)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError($api, AccNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc delete*(acc: CoreDbAccRef, accPath: Hash256): CoreDbRc[void] =
  ## Delete the particular account indexed by the key `accPath`. This
  ## will also destroy an associated storage area.
  ##
  acc.setTrackNewApi AccDeleteFn
  result = block:
    let rc = acc.call(deleteAccountRecord, acc.mpt, accPath)
    if rc.isOk:
      ok()
    elif rc.error == DelPathNotFound:
      # TODO: Would it be conseqient to just return `ok()` here?
      err(rc.error.toError($api, AccNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc clearStorage*(acc: CoreDbAccRef, accPath: Hash256): CoreDbRc[void] =
  ## Delete all data slots from the storage area associated with the
  ## particular account indexed by the key `accPath`.
  ##
  acc.setTrackNewApi AccClearStorageFn
  result = block:
    let rc = acc.call(deleteStorageTree, acc.mpt, accPath)
    if rc.isOk or rc.error in {DelStoRootMissing, DelStoAccMissing}:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc merge*(
    acc: CoreDbAccRef, accPath: Hash256, accRec: CoreDbAccount
): CoreDbRc[void] =
  ## Add or update the argument account data record `account`. Note that the
  ## `account` argument uniquely idendifies the particular account address.
  ##
  acc.setTrackNewApi AccMergeFn
  result = block:
    let rc = acc.call(mergeAccountRecord, acc.mpt, accPath, accRec)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc hasPath*(acc: CoreDbAccRef, accPath: Hash256): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  result = block:
    let rc = acc.call(hasPathAccount, acc.mpt, accPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc state*(acc: CoreDbAccRef, updateOk = false): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the accounts
  ## column (if available.)
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  acc.setTrackNewApi AccStateFn
  result = block:
    let rc = acc.call(fetchAccountState, acc.mpt, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, updateOK, result

# ------------ storage ---------------

proc slotFetch*(
    acc: CoreDbAccRef, accPath: Hash256, stoPath: Hash256
): CoreDbRc[UInt256] =
  ## Like `fetch()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotFetchFn
  result = block:
    let rc = acc.call(fetchStorageData, acc.mpt, accPath, stoPath)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError($api, StoNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), stoPath = ($$stoPath), result

proc slotDelete*(
    acc: CoreDbAccRef, accPath: Hash256, stoPath: Hash256
): CoreDbRc[void] =
  ## Like `delete()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotDeleteFn
  result = block:
    let rc = acc.call(deleteStorageData, acc.mpt, accPath, stoPath)
    if rc.isOk or rc.error == DelStoRootMissing:
      # The second `if` clause is insane but legit: A storage column was
      # announced for an account but no data have been added, yet.
      ok()
    elif rc.error == DelPathNotFound:
      err(rc.error.toError($api, StoNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), stoPath = ($$stoPath), result

proc slotHasPath*(
    acc: CoreDbAccRef, accPath: Hash256, stoPath: Hash256
): CoreDbRc[bool] =
  ## Like `hasPath()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotHasPathFn
  result = block:
    let rc = acc.call(hasPathStorage, acc.mpt, accPath, stoPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), stoPath = ($$stoPath), result

proc slotMerge*(
    acc: CoreDbAccRef, accPath: Hash256, stoPath: Hash256, stoData: UInt256
): CoreDbRc[void] =
  ## Like `merge()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotMergeFn
  result = block:
    let rc = acc.call(mergeStorageData, acc.mpt, accPath, stoPath, stoData)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt,
      api, elapsed, accPath = ($$accPath), stoPath = ($$stoPath), stoData, result

proc slotState*(
    acc: CoreDbAccRef, accPath: Hash256, updateOk = false
): CoreDbRc[Hash256] =
  ## This function retrieves the Merkle state hash of the storage data
  ## column (if available) related to the account  indexed by the key
  ## `accPath`.`.
  ##
  ## If the argument `updateOk` is set `true`, the Merkle hashes of the
  ## database will be updated first (if needed, at all).
  ##
  acc.setTrackNewApi AccSlotStateFn
  result = block:
    let rc = acc.call(fetchStorageState, acc.mpt, accPath, updateOk)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), updateOk, result

proc slotStateEmpty*(acc: CoreDbAccRef, accPath: Hash256): CoreDbRc[bool] =
  ## This function returns `true` if the storage data column is empty or
  ## missing.
  ##
  acc.setTrackNewApi AccSlotStateEmptyFn
  result = block:
    let rc = acc.call(hasStorageData, acc.mpt, accPath)
    if rc.isOk:
      ok(not rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

proc slotStateEmptyOrVoid*(acc: CoreDbAccRef, accPath: Hash256): bool =
  ## Convenience wrapper, returns `true` where `slotStateEmpty()` would fail.
  acc.setTrackNewApi AccSlotStateEmptyOrVoidFn
  result = block:
    let rc = acc.call(hasStorageData, acc.mpt, accPath)
    if rc.isOk:
      not rc.value
    else:
      true
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath = ($$accPath), result

# ------------- other ----------------

proc recast*(
    acc: CoreDbAccRef, accPath: Hash256, accRec: CoreDbAccount, updateOk = false
): CoreDbRc[Account] =
  ## Complete the argument `accRec` to the portable Ethereum representation
  ## of an account statement. This conversion may fail if the storage colState
  ## hash (see `slotState()` above) is currently unavailable.
  ##
  acc.setTrackNewApi AccRecastFn
  let rc = acc.call(fetchStorageState, acc.mpt, accPath, updateOk)
  result = block:
    if rc.isOk:
      ok Account(
        nonce: accRec.nonce,
        balance: accRec.balance,
        codeHash: accRec.codeHash,
        storageRoot: rc.value,
      )
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    let slotState =
      if rc.isOk:
        $$(rc.value)
      else:
        "n/a"
    debug logTxt, api, elapsed, accPath = ($$accPath), slotState, result

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc level*(db: CoreDbRef): int =
  ## Retrieve transaction level (zero if there is no pending transaction).
  ##
  db.setTrackNewApi BaseLevelFn
  result = CoreDbAccRef(db.ctx).call(level, db.ctx.mpt)
  db.ifTrackNewApi:
    debug logTxt, api, elapsed, result

proc newTransaction*(ctx: CoreDbCtxRef): CoreDbTxRef =
  ## Constructor
  ##
  ctx.setTrackNewApi BaseNewTxFn
  let
    kTx = CoreDbKvtRef(ctx).call(txBegin, ctx.kvt).valueOr:
        raiseAssert $api & ": " & $error
    aTx = CoreDbAccRef(ctx).call(txBegin, ctx.mpt).valueOr:
        raiseAssert $api & ": " & $error
  result = ctx.bless CoreDbTxRef(kTx: kTx, aTx: aTx)
  ctx.ifTrackNewApi:
    let newLevel = CoreDbAccRef(ctx).call(level, ctx.mpt)
    debug logTxt, api, elapsed, newLevel

proc level*(tx: CoreDbTxRef): int =
  ## Print positive transaction level for argument `tx`
  ##
  tx.setTrackNewApi TxLevelFn
  result = CoreDbAccRef(tx.ctx).call(txLevel, tx.aTx)
  tx.ifTrackNewApi:
    debug logTxt, api, elapsed, result

proc commit*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(txLevel, tx.aTx)
  CoreDbAccRef(tx.ctx).call(commit, tx.aTx).isOkOr:
    raiseAssert $api & ": " & $error
  CoreDbKvtRef(tx.ctx).call(commit, tx.kTx).isOkOr:
    raiseAssert $api & ": " & $error
  tx.ifTrackNewApi:
    debug logTxt, api, elapsed, prvLevel

proc rollback*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(txLevel, tx.aTx)
  CoreDbAccRef(tx.ctx).call(rollback, tx.aTx).isOkOr:
    raiseAssert $api & ": " & $error
  CoreDbKvtRef(tx.ctx).call(rollback, tx.kTx).isOkOr:
    raiseAssert $api & ": " & $error
  tx.ifTrackNewApi:
    debug logTxt, api, elapsed, prvLevel

proc dispose*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(txLevel, tx.aTx)
  if CoreDbAccRef(tx.ctx).call(isTop, tx.aTx):
    CoreDbAccRef(tx.ctx).call(rollback, tx.aTx).isOkOr:
      raiseAssert $api & ": " & $error
  if CoreDbKvtRef(tx.ctx).call(isTop, tx.kTx):
    CoreDbKvtRef(tx.ctx).call(rollback, tx.kTx).isOkOr:
      raiseAssert $api & ": " & $error
  tx.ifTrackNewApi:
    debug logTxt, api, elapsed, prvLevel

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

when false: # currently disabled
  proc newCapture*(db: CoreDbRef): CoreDbRc[CoreDbCaptRef] =
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
    db.ifTrackNewApi:
      debug logTxt, api, elapsed, result

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
    cpt.ifTrackNewApi:
      debug logTxt, api, elapsed

  proc logDb*(cp: CoreDbCaptRef): TableRef[Blob, Blob] =
    ## Getter, returns the logger table for the overlay tracer database.
    ##
    ## Caveat:
    ##   Unless the desriptor `cpt` referes to the top level overlay tracer, the
    ##   result is undefined and depends on the backend implementation of the
    ##   tracer.
    ##
    cp.setTrackNewApi CptLogDbFn
    result = cp.methods.logDbFn()
    cp.ifTrackNewApi:
      debug logTxt, api, elapsed

  proc flags*(cp: CoreDbCaptRef): set[CoreDbCaptFlags] =
    ## Getter
    ##
    cp.setTrackNewApi CptFlagsFn
    result = cp.methods.getFlagsFn()
    cp.ifTrackNewApi:
      debug logTxt, api, elapsed, result

  proc forget*(cp: CoreDbCaptRef) =
    ## Explicitely stop recording the current tracer instance and reset to
    ## previous level.
    ##
    cp.setTrackNewApi CptForgetFn
    cp.methods.forgetFn()
    cp.ifTrackNewApi:
      debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
