# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  eth/common/[accounts, base, hashes],
  ../../constants,
  ../[kvt, aristo],
  ./base/[api_tracking, base_config, base_desc, base_helpers]

export
  CoreDbAccRef,
  CoreDbAccount,
  CoreDbCtxRef,
  CoreDbErrorCode,
  CoreDbError,
  CoreDbKvtRef,
  CoreDbPersistentTypes,
  CoreDbRef,
  CoreDbTxRef,
  CoreDbType

when CoreDbEnableApiTracking:
  import
    chronicles
  logScope:
    topics = "core_db"
  const
    logTxt = "API"

when CoreDbEnableProfiling:
  export
    CoreDbFnInx,
    CoreDbProfListRef

when CoreDbEnableCaptJournal:
  import
    ./backend/aristo_trace
  type
    CoreDbCaptRef* = distinct TraceLogInstRef
  func `$`(p: CoreDbCaptRef): string =
    if p.distinctBase.isNil: "<nil>" else: "<capt>"
else:
  import
    ../aristo/[
      aristo_delete, aristo_desc, aristo_fetch, aristo_merge, aristo_part,
      aristo_tx],
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

proc baseTxFrame*(db: CoreDbRef): CoreDbTxRef =
  ## The base tx frame is a staging are for reading and writing "almost"
  ## directly from/to the database without using any pending frames - when a
  ## transaction created using `beginTxFrame` is committed, it ultimately ends
  ## up in the base txframe before being persisted to the database with a
  ## persist call.

  CoreDbTxRef(
    ctx: db.ctx,
    aTx: db.ctx.parent.ariApi.call(baseTxFrame, db.ctx.mpt),
    kTx: db.ctx.parent.kvtApi.call(baseTxFrame, db.ctx.kvt))

# ------------------------------------------------------------------------------
# Public base descriptor methods
# ------------------------------------------------------------------------------

proc finish*(db: CoreDbRef; eradicate = false) =
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
  db.ifTrackNewApi: debug logTxt, api, elapsed

proc `$$`*(e: CoreDbError): string =
  ## Pretty print error symbol
  ##
  e.toStr()

proc persistent*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
      ): CoreDbRc[void] =
  ## This function stored cached data from the default context (see `ctx()`
  ## below) to the persistent database.
  ##
  ## It also stores the argument block number `blockNumber` as a state record
  ## which can be retrieved via `stateBlockNumber()`.
  ##
  db.setTrackNewApi BasePersistentFn
  block body:
    let rc = CoreDbKvtRef(db.ctx).call(persist, db.ctx.kvt)
    if rc.isOk or rc.error == TxPersistDelayed:
      # The latter clause is OK: Piggybacking on `Aristo` backend
      discard
    else:
      result = err(rc.error.toError $api)
      break body

    # Having reached here `Aristo` must not fail as both `Kvt` and `Aristo`
    # are kept in sync. So if there is a legit fail condition it mist be
    # caught in the previous clause.
    CoreDbAccRef(db.ctx).call(persist, db.ctx.mpt, blockNumber).isOkOr:
      raiseAssert $api & ": " & $error
    result = ok()
  db.ifTrackNewApi: debug logTxt, api, elapsed, blockNumber, result

proc stateBlockNumber*(db: CoreDbTxRef): BlockNumber =
  ## This function returns the block number stored with the latest `persist()`
  ## directive.
  ##
  db.setTrackNewApi BaseStateBlockNumberFn
  result = block:
    let rc = db.ctx.parent.ariApi.call(fetchLastSavedState, db.aTx)
    if rc.isOk:
      rc.value.serial.BlockNumber
    else:
      0u64
  db.ifTrackNewApi: debug logTxt, api, elapsed, result

proc verify*(
    db: CoreDbRef | CoreDbAccRef;
    proof: openArray[seq[byte]];
    root: Hash32;
    path: Hash32;
      ): CoreDbRc[Opt[seq[byte]]] =
  ## Variant of `verify()`.
  template mpt: untyped =
    when db is CoreDbRef:
      CoreDbAccRef(db.defCtx)
    else:
      db
  mpt.setTrackNewApi BaseVerifyFn
  result = block:
    let rc = mpt.call(partUntwigPath, proof, root, path)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError($api, ProofVerify))
  mpt.ifTrackNewApi: debug logTxt, api, elapsed, result

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

proc get*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[seq[byte]] =
  ## This function always returns a non-empty `seq[byte]` or an error code.
  kvt.setTrackNewApi KvtGetFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(get, kvt.kTx, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError($api, KvtNotFound))
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[seq[byte]] =
  ## Variant of `get()` returning an empty `seq[byte]` if the key is not found
  ## on the database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(get, kvt.kTx, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      CoreDbRc[seq[byte]].ok(EmptyBlob)
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

proc len*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[int] =
  ## This function returns the size of the value associated with `key`.
  kvt.setTrackNewApi KvtLenFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(len, kvt.kTx, key)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == GetNotFound:
      err(rc.error.toError($api, KvtNotFound))
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

proc del*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(del, kvt.kTx, key)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDbTxRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(put, kvt.kTx, key, val)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi:
    debug logTxt, api, elapsed, key=key.toStr, val=val.toLenStr, result

proc hasKeyRc*(kvt: CoreDbTxRef; key: openArray[byte]): CoreDbRc[bool] =
  ## For the argument `key` return `true` if `get()` returned a value on
  ## that argument, `false` if it returned `GetNotFound`, and an error
  ## otherwise.
  ##
  kvt.setTrackNewApi KvtHasKeyRcFn
  result = block:
    let rc = kvt.ctx.parent.kvtApi.call(hasKeyRc, kvt.kTx, key)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

proc hasKey*(kvt: CoreDbTxRef; key: openArray[byte]): bool =
  ## Simplified version of `hasKeyRc` where `false` is returned instead of
  ## an error.
  ##
  ## This function prototype is in line with the `hasKey` function for
  ## `Tables`.
  ##
  kvt.setTrackNewApi KvtHasKeyFn
  result = kvt.ctx.parent.kvtApi.call(hasKeyRc, kvt.kTx, key).valueOr: false
  kvt.ifTrackNewApi: debug logTxt, api, elapsed, key=key.toStr, result

# ------------------------------------------------------------------------------
# Public methods for accounts
# ------------------------------------------------------------------------------

proc getAccounts*(ctx: CoreDbCtxRef): CoreDbAccRef =
  ## Accounts column constructor, will defect on failure.
  ##
  ctx.setTrackNewApi CtxGetAccountsFn
  result =  CoreDbAccRef(ctx)
  ctx.ifTrackNewApi: debug logTxt, api, elapsed

# ----------- accounts ---------------

proc proof*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[(seq[seq[byte]],bool)] =
  ## On the accounts MPT, collect the nodes along the `accPath` interpreted as
  ## path. Return these path nodes as a chain of rlp-encoded blobs followed
  ## by a bool value which is `true` if the `key` path exists in the database,
  ## and `false` otherwise. In the latter case, the chain of rlp-encoded blobs
  ## are the nodes proving that the `key` path does not exist.
  ##
  acc.setTrackNewApi AccProofFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(partAccountTwig, acc.aTx, accPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError($api, ProofCreate))
  acc.ifTrackNewApi: debug logTxt, api, elapsed, result

proc fetch*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[CoreDbAccount] =
  ## Fetch the account data record for the particular account indexed by
  ## the key `accPath`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(fetchAccountRecord, acc.aTx, accPath)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError($api, AccNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi: debug logTxt, api, elapsed, accPath=($$accPath), result

proc delete*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[void] =
  ## Delete the particular account indexed by the key `accPath`. This
  ## will also destroy an associated storage area.
  ##
  acc.setTrackNewApi AccDeleteFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(deleteAccountRecord, acc.aTx, accPath)
    if rc.isOk:
      ok()
    elif rc.error == DelPathNotFound:
      # TODO: Would it be conseqient to just return `ok()` here?
      err(rc.error.toError($api, AccNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc clearStorage*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[void] =
  ## Delete all data slots from the storage area associated with the
  ## particular account indexed by the key `accPath`.
  ##
  acc.setTrackNewApi AccClearStorageFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(deleteStorageTree, acc.aTx, accPath)
    if rc.isOk or rc.error in {DelStoRootMissing,DelStoAccMissing}:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc merge*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    accRec: CoreDbAccount;
      ): CoreDbRc[void] =
  ## Add or update the argument account data record `account`. Note that the
  ## `account` argument uniquely idendifies the particular account address.
  ##
  acc.setTrackNewApi AccMergeFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(mergeAccountRecord, acc.aTx, accPath, accRec)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc hasPath*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(hasPathAccount, acc.aTx, accPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc getStateRoot*(acc: CoreDbTxRef): CoreDbRc[Hash32] =
  ## This function retrieves the Merkle state hash of the accounts
  ## column (if available.)
  acc.setTrackNewApi AccStateFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(fetchStateRoot, acc.aTx)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi: debug logTxt, api, elapsed, result

# ------------ storage ---------------

proc slotProof*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): CoreDbRc[(seq[seq[byte]],bool)] =
  ## On the storage MPT related to the argument account `acPath`, collect the
  ## nodes along the `stoPath` interpreted as path. Return these path nodes as
  ## a chain of rlp-encoded blobs followed by a bool value which is `true` if
  ## the `key` path exists in the database, and `false` otherwise. In the
  ## latter case, the chain of rlp-encoded blobs are the nodes proving that
  ## the `key` path does not exist.
  ##
  ## Note that the function always returns an error unless the `accPath` is
  ## valid.
  ##
  acc.setTrackNewApi AccSlotProofFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(partStorageTwig, acc.aTx, accPath, stoPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError($api, ProofCreate))
  acc.ifTrackNewApi: debug logTxt, api, elapsed, result

proc slotFetch*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ):  CoreDbRc[UInt256] =
  ## Like `fetch()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotFetchFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(fetchStorageData, acc.aTx, accPath, stoPath)
    if rc.isOk:
      ok(rc.value)
    elif rc.error == FetchPathNotFound:
      err(rc.error.toError($api, StoNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath),
            stoPath=($$stoPath), result

proc slotDelete*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ):  CoreDbRc[void] =
  ## Like `delete()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotDeleteFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(deleteStorageData, acc.aTx, accPath, stoPath)
    if rc.isOk or rc.error == DelStoRootMissing:
      # The second `if` clause is insane but legit: A storage column was
      # announced for an account but no data have been added, yet.
      ok()
    elif rc.error == DelPathNotFound:
      err(rc.error.toError($api, StoNotFound))
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath),
            stoPath=($$stoPath), result

proc slotHasPath*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ):  CoreDbRc[bool] =
  ## Like `hasPath()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotHasPathFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(hasPathStorage, acc.aTx, accPath, stoPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath),
            stoPath=($$stoPath), result

proc slotMerge*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    stoPath: Hash32;
    stoData: UInt256;
      ):  CoreDbRc[void] =
  ## Like `merge()` but with cascaded index `(accPath,slot)`.
  acc.setTrackNewApi AccSlotMergeFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(mergeStorageData, acc.aTx, accPath, stoPath, stoData)
    if rc.isOk:
      ok()
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath),
            stoPath=($$stoPath), stoData, result

proc slotStorageRoot*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ):  CoreDbRc[Hash32] =
  ## This function retrieves the Merkle state hash of the storage data
  ## column (if available) related to the account  indexed by the key
  ## `accPath`.`.
  ##
  acc.setTrackNewApi AccSlotStorageRootFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(fetchStorageRoot, acc.aTx, accPath)
    if rc.isOk:
      ok(rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc slotStorageEmpty*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ):  CoreDbRc[bool] =
  ## This function returns `true` if the storage data column is empty or
  ## missing.
  ##
  acc.setTrackNewApi AccSlotStorageEmptyFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(hasStorageData, acc.aTx, accPath)
    if rc.isOk:
      ok(not rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

proc slotStorageEmptyOrVoid*(
    acc: CoreDbTxRef;
    accPath: Hash32;
      ): bool =
  ## Convenience wrapper, returns `true` where `slotStorageEmpty()` would fail.
  acc.setTrackNewApi AccSlotStorageEmptyOrVoidFn
  result = block:
    let rc = acc.ctx.parent.ariApi.call(hasStorageData, acc.aTx, accPath)
    if rc.isOk:
      not rc.value
    else:
      true
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed, accPath=($$accPath), result

# ------------- other ----------------

proc recast*(
    acc: CoreDbTxRef;
    accPath: Hash32;
    accRec: CoreDbAccount;
      ): CoreDbRc[Account] =
  ## Complete the argument `accRec` to the portable Ethereum representation
  ## of an account statement. This conversion may fail if the storage colState
  ## hash (see `slotStorageRoot()` above) is currently unavailable.
  ##
  acc.setTrackNewApi AccRecastFn
  let rc = acc.ctx.parent.ariApi.call(fetchStorageRoot, acc.aTx, accPath)
  result = block:
    if rc.isOk:
      ok Account(
        nonce:       accRec.nonce,
        balance:     accRec.balance,
        codeHash:    accRec.codeHash,
        storageRoot: rc.value)
    else:
      err(rc.error.toError $api)
  acc.ifTrackNewApi:
    let storageRoot = if rc.isOk: $$(rc.value) else: "n/a"
    debug logTxt, api, elapsed, accPath=($$accPath), storageRoot, result

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc txFrameBegin*(ctx: CoreDbCtxRef, parent: CoreDbTxRef): CoreDbTxRef =
  ## Constructor
  ##
  ctx.setTrackNewApi BaseNewTxFn
  let
    kTx = CoreDbKvtRef(ctx).call(txFrameBegin, ctx.kvt, if parent != nil: parent.kTx else: nil).valueOr:
      raiseAssert $api & ": " & $error
    aTx = CoreDbAccRef(ctx).call(txFrameBegin, ctx.mpt, if parent != nil: parent.aTx else: nil).valueOr:
      raiseAssert $api & ": " & $error
  result = ctx.bless CoreDbTxRef(kTx: kTx, aTx: aTx)
  ctx.ifTrackNewApi:
    let newLevel = CoreDbAccRef(ctx).call(level, ctx.mpt)
    debug logTxt, api, elapsed, newLevel

proc commit*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(level, tx.aTx)
  CoreDbAccRef(tx.ctx).call(commit, tx.aTx).isOkOr:
    raiseAssert $api & ": " & $error
  CoreDbKvtRef(tx.ctx).call(commit, tx.kTx).isOkOr:
    raiseAssert $api & ": " & $error
  tx.ifTrackNewApi: debug logTxt, api, elapsed, prvLevel

proc rollback*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(level, tx.aTx)
  CoreDbAccRef(tx.ctx).call(rollback, tx.aTx).isOkOr:
    raiseAssert $api & ": " & $error
  CoreDbKvtRef(tx.ctx).call(rollback, tx.kTx).isOkOr:
    raiseAssert $api & ": " & $error
  tx.ifTrackNewApi: debug logTxt, api, elapsed, prvLevel

proc dispose*(tx: CoreDbTxRef) =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = CoreDbAccRef(tx.ctx).call(level, tx.aTx)
  # if CoreDbAccRef(tx.ctx).call(isTop, tx.aTx):
  CoreDbAccRef(tx.ctx).call(rollback, tx.aTx).isOkOr:
    raiseAssert $api & ": " & $error
  # if CoreDbKvtRef(tx.ctx).call(isTop, tx.kTx):
  CoreDbKvtRef(tx.ctx).call(rollback, tx.kTx).isOkOr:
    raiseAssert $api & ": " & $error
  tx.ifTrackNewApi: debug logTxt, api, elapsed, prvLevel

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

when CoreDbEnableCaptJournal:
  proc pushCapture*(db: CoreDbRef): CoreDbCaptRef =
    ## ..
    ##
    db.setTrackNewApi BasePushCaptureFn
    if db.tracerHook.isNil:
      db.tracerHook = TraceRecorderRef.init(db)
    else:
      TraceRecorderRef(db.tracerHook).push()
    result = TraceRecorderRef(db.tracerHook).topInst().CoreDbCaptRef
    db.ifTrackNewApi: debug logTxt, api, elapsed, result

  proc level*(cpt: CoreDbCaptRef): int =
    ## Getter, returns the positive number of stacked instances.
    ##
    let log = cpt.distinctBase
    log.db.setTrackNewApi CptLevelFn
    result = log.level()
    log.db.ifTrackNewApi: debug logTxt, api, elapsed, result

  proc kvtLog*(cpt: CoreDbCaptRef): seq[(seq[byte],seq[byte])] =
    ## Getter, returns the `Kvt` logger list for the argument instance.
    ##
    let log = cpt.distinctBase
    log.db.setTrackNewApi CptKvtLogFn
    result = log.kvtLogBlobs()
    log.db.ifTrackNewApi: debug logTxt, api, elapsed

  proc pop*(cpt: CoreDbCaptRef) =
    ## Explicitely stop recording the current tracer instance and reset to
    ## previous level.
    ##
    let db = cpt.distinctBase.db
    db.setTrackNewApi CptPopFn
    if not cpt.distinctBase.pop():
      TraceRecorderRef(db.tracerHook).restore()
      db.tracerHook = TraceRecorderRef(nil)
    db.ifTrackNewApi: debug logTxt, api, elapsed, cpt

  proc stopCapture*(db: CoreDbRef) =
    ## Discard capture instances. This function is equivalent to `pop()`-ing
    ## all instances.
    ##
    db.setTrackNewApi CptStopCaptureFn
    if not db.tracerHook.isNil:
      TraceRecorderRef(db.tracerHook).restore()
      db.tracerHook = TraceRecorderRef(nil)
    db.ifTrackNewApi: debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
