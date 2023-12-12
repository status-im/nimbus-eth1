# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
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
  results,
  "../.."/[constants, errors],
  ../aristo/aristo_constants, # `EmptyBlob`
  ./base/[api_new_desc, api_tracking, base_desc]

const
  ProvideLegacyAPI = true
    ## Enable legacy API. For now everybody would want this enabled.

  EnableApiTracking = false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Tracking is enabled by setting `true` the flags
    ## `trackLegaApi` and/or `trackNewApi` in the `CoreDxTxRef` descriptor.

  EnableApiProfiling = true
    ## Enables functions profiling if `EnableApiTracking` is also set `true`.

  AutoValidateDescriptors = defined(release).not
    ## No validatinon needed for production suite.


export
  CoreDbAccBackendRef,
  CoreDbAccount,
  CoreDbApiError,
  CoreDbBackendRef,
  CoreDbCaptFlags,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbFnInx,
  CoreDbKvtBackendRef,
  CoreDbMptBackendRef,
  CoreDbPersistentTypes,
  CoreDbRef,
  CoreDbSaveFlags,
  CoreDbType,
  CoreDbVidRef,
  CoreDxAccRef,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxRef,

  # Profiling support
  byElapsed,
  byMean,
  byVisits,
  stats

const
  CoreDbProvideLegacyAPI* = ProvideLegacyAPI
  CoreDbEnableApiTracking* = EnableApiTracking
  CoreDbEnableApiProfiling* = EnableApiTracking and EnableApiProfiling

when ProvideLegacyAPI:
  import
    ./base/api_legacy_desc
  export
    api_legacy_desc

when AutoValidateDescriptors:
  import ./base/validate

when EnableApiTracking and EnableApiProfiling:
  var coreDbProfTab*: CoreDbProfFnInx


# More settings
const
  logTxt = "CoreDb "

  legaApiTxt = logTxt & "legacy API"

  newApiTxt = logTxt & "new API"

# Annotation helpers
{.pragma:   apiRaise, gcsafe, raises: [CoreDbApiError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template itNotImplemented(db: CoreDbRef, name: string) =
  warn logTxt & "iterator not implemented", dbType=db.dbType, meth=name

# ---------

when EnableApiTracking:
  when EnableApiProfiling:
    {.warning: "*** Provided API profiling for CoreDB (disabled by default)".}
  else:
    {.warning: "*** Provided API logging for CoreDB (disabled by default)".}

  import
    std/[sequtils, times]

  proc `$`[T](rc: CoreDbRc[T]): string = rc.toStr
  proc `$`(q: set[CoreDbCaptFlags]): string = q.toStr
  proc `$`(t: Duration): string = t.toStr
  proc `$`(e: EthAddress): string = e.toStr
  proc `$`(v: CoreDbVidRef): string = v.toStr


when ProvideLegacyAPI:
  when EnableApiTracking:
    proc `$`(k: CoreDbKvtRef): string = k.toStr

  template setTrackLegaApi(
      w: CoreDbApiTrackRef;
      s: static[CoreDbFnInx];
      code: untyped;
        ) =
    ## Template with code section that will be discarded if logging is
    ## disabled at compile time when `EnableApiTracking` is `false`.
    when EnableApiTracking:
      w.beginLegaApi()
      code
    const ctx {.inject,used.} = s

  template setTrackLegaApi(
      w: CoreDbApiTrackRef;
      s: static[CoreDbFnInx];
        ) =
    w.setTrackLegaApi(s):
      discard

  template ifTrackLegaApi(w: CoreDbApiTrackRef; code: untyped) =
    when EnableApiTracking:
      w.endLegaApiIf:
        when EnableApiProfiling:
          coreDbProfTab.update(ctx, elapsed)
        code


template setTrackNewApi(
    w: CoreDxApiTrackRef;
    s: static[CoreDbFnInx];
    code: untyped;
      ) =
  ## Template with code section that will be discarded if logging is
  ## disabled at compile time when `EnableApiTracking` is `false`.
  when EnableApiTracking:
    w.beginNewApi()
    code
  const ctx {.inject,used.} = s

template setTrackNewApi(
    w: CoreDxApiTrackRef;
    s: static[CoreDbFnInx];
      ) =
  w.setTrackNewApi(s):
    discard

template ifTrackNewApi(w: CoreDxApiTrackRef; code: untyped) =
  when EnableApiTracking:
    w.endNewApiIf:
      when EnableApiProfiling:
        coreDbProfTab.update(ctx, elapsed)
      code

# ---------

func toCoreDxPhkRef(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## MPT => pre-hashed MPT (aka PHK)
  result = CoreDxPhkRef(
    fromMpt: mpt,
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

  result.methods.pairsIt =
    iterator(): (Blob, Blob) =
      mpt.parent.itNotImplemented("phk/pairs()")

  result.methods.replicateIt =
    iterator(): (Blob, Blob) =
      mpt.parent.itNotImplemented("phk/replicate()")

  when AutoValidateDescriptors:
    result.validate


func parent(phk: CoreDxPhkRef): CoreDbRef =
  phk.fromMpt.parent

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------


proc bless*(db: CoreDbRef): CoreDbRef =
  ## Verify descriptor
  when AutoValidateDescriptors:
    db.validate
  db


proc bless*(db: CoreDbRef; child: CoreDbVidRef): CoreDbVidRef =
  ## Complete sub-module descriptor, fill in `parent` and actvate it.
  child.parent = db
  child.ready = true
  when AutoValidateDescriptors:
    child.validate
  child


proc bless*(db: CoreDbRef; child: CoreDxKvtRef): CoreDxKvtRef =
  ## Complete sub-module descriptor, fill in `parent` and de-actvate
  ## iterator for persistent database.
  child.parent = db

  # Disable interator for non-memory instances
  if db.dbType in CoreDbPersistentTypes:
    child.methods.pairsIt = iterator(): (Blob, Blob) =
      db.itNotImplemented "pairs/kvt"

  when AutoValidateDescriptors:
    child.validate
  child


proc bless*[T: CoreDxTrieRelated | CoreDbBackends](
    db: CoreDbRef;
    child: T;
      ): auto =
  ## Complete sub-module descriptor, fill in `parent`.
  child.parent = db
  when AutoValidateDescriptors:
    child.validate
  child


proc bless*(
    db: CoreDbRef;
    error: CoreDbErrorCode;
    child: CoreDbErrorRef;
      ): CoreDbErrorRef =
  child.parent = db
  child.error = error
  when AutoValidateDescriptors:
    child.validate
  child

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc dbType*(db: CoreDbRef): CoreDbType =
  ## Getter
  db.setTrackNewApi BaseDbTypeFn
  result = db.dbType
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc compensateLegacySetup*(db: CoreDbRef) =
  ## On the persistent legacy hexary trie, this function is needed for
  ## bootstrapping and Genesis setup when the `purge` flag is activated.
  ## Otherwise the database backend may defect on an internal inconsistency.
  ##
  db.setTrackNewApi BaseLegacySetupFn
  db.methods.legacySetupFn()
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc level*(db: CoreDbRef): int =
  ## Print transaction level, zero if there is no pending transaction
  ##
  db.setTrackNewApi BaseLevelFn
  result = db.methods.levelFn()
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc parent*(cld: CoreDxChldRefs): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = cld.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxTrieRelated | CoreDbRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  dsc.setTrackNewApi AnyBackendFn
  result = dsc.methods.backendFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed

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
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc `$$`*(e: CoreDbErrorRef): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  ##
  e.setTrackNewApi ErrorPrintFn
  result = $e.error & "(" & e.parent.methods.errorPrintFn(e) & ")"
  e.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc hash*(vid: CoreDbVidRef; update: bool): CoreDbRc[Hash256] =
  ## Getter (well, sort of), retrieves the hash for a `vid` argument. The
  ## function might fail if there is currently no hash available (e.g. on
  ## `Aristo`.) Note that this is different from succeeding with an
  ## `EMPTY_ROOT_HASH` value.
  ##
  ## The value `EMPTY_ROOT_HASH` is also returned on an empty `vid` argument
  ## `CoreDbVidRef(nil)`, say.
  ##
  vid.setTrackNewApi VidHashFn
  result = block:
    if not vid.isNil and vid.ready:
      vid.parent.methods.vidHashFn(vid, update)
    else:
      ok EMPTY_ROOT_HASH
  # Note: tracker will be silent if `vid` is NIL
  vid.ifTrackNewApi: debug newApiTxt, ctx, elapsed, vid=vid.toStr, result

proc hashOrEmpty*(vid: CoreDbVidRef): Hash256 =
  ## Convenience wrapper, returns `EMPTY_ROOT_HASH` where `hash()` would fail.
  vid.hash(update = true).valueOr: EMPTY_ROOT_HASH

proc recast*(account: CoreDbAccount; update: bool): CoreDbRc[Account] =
  ## Convert the argument `account` to the portable Ethereum representation
  ## of an account. This conversion may fail if the storage root hash (see
  ## `hash()` above) is currently unavailable.
  ##
  ## Note that for the legacy backend, this function always succeeds.
  ##
  let vid = account.storageVid
  vid.setTrackNewApi EthAccRecastFn
  result = block:
    let rc = vid.hash(update)
    if rc.isOk:
      ok Account(
        nonce:       account.nonce,
        balance:     account.balance,
        codeHash:    account.codeHash,
        storageRoot: rc.value)
    else:
      err(rc.error)
  vid.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc getRoot*(
    db: CoreDbRef;
    root: Hash256;
    createOk = false;
      ): CoreDbRc[CoreDbVidRef] =
  ## Find root node with argument hash `root` in database and return the
  ## corresponding `CoreDbVidRef` object. If the `root` arguent is set
  ## `EMPTY_CODE_HASH`, this function always succeeds, otherwise it fails
  ## unless a root node with the corresponding hash exists.
  ##
  ## This function is intended to open a virtual accounts trie database as in:
  ## ::
  ##   proc openAccountLedger(db: CoreDbRef, rootHash: Hash256): CoreDxMptRef =
  ##     let root = db.getRoot(rootHash).valueOr:
  ##       # some error handling
  ##       return
  ##     db.newAccMpt root
  ##
  db.setTrackNewApi BaseGetRootFn
  result = db.methods.getRootFn(root, createOk)
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, root=root.toStr, result

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc newKvt*(db: CoreDbRef; saveMode = AutoSave): CoreDxKvtRef =
  ## Constructor, will defect on failure.
  ##
  ## Depending on the argument `saveMode`, the contructed object will have
  ## the following properties.
  ##
  ## * `Shared`
  ##   Subscribe to the common base object shared with other subscribed
  ##   `AutoSave` or `Shared` descriptors. So any changes are immediately
  ##   visible among subscribers. On automatic destruction (when the
  ##   constructed object gets out of scope), changes are not saved to the
  ##   backend database but are still available to subscribers.
  ##
  ##   This mode would used for short time read-only database descriptors.
  ##
  ## * `AutoSave`
  ##   This mode works similar to `Shared` with the difference that changes
  ##   are saved to the backend database on automatic destruction when this
  ##   is permissible, i.e. there is a backend available and there is no
  ##   pending transaction on the common base object.
  ##
  ## * `TopShot`
  ##   The contructed object will be a new descriptor with a separate snapshot
  ##   of the common shared base object. If there are pending transactions
  ##   on the shared  base object, the snapsot will squash them to a single
  ##   pending transaction. On automatic destruction, changes will be discarded.
  ##
  ## * `Companion`
  ##   The contructed object will be a new  separate descriptor with a clean
  ##   cache (similar to `TopShot` with empty cache and no pending
  ##   transactions.) On automatic destruction, changes will be discarded.
  ##
  ## The constructed object can be manually descructed (see `forget()`) without
  ## saving and can be forced to save (see `persistent()`.)
  ##
  ## The legacy backend always assumes `AutoSave` mode regardless of the
  ## function argument.
  ##
  db.setTrackNewApi BaseNewKvtFn
  result = db.methods.newKvtFn(saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, saveMode

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi KvtGetFn
  result = kvt.methods.getFn key
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function sort of mimics the behaviour of the legacy database
  ## returning an empty `Blob` if the argument `key` is not found on the
  ## database.
  ##
  kvt.setTrackNewApi KvtGetOrEmptyFn
  result = kvt.methods.getFn key
  if result.isErr and result.error.error == KvtNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc del*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi KvtDelFn
  result = kvt.methods.delFn key
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDxKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi KvtPutFn
  result = kvt.methods.putFn(key, val)
  kvt.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr, result

proc hasKey*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  kvt.setTrackNewApi KvtHasKeyFn
  result = kvt.methods.hasKeyFn key
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc persistent*(dsc: CoreDxKvtRef): CoreDbRc[void] {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ## It will nevertheless return a discardable error if there is a pending
  ## transaction.
  ##
  ## This function saves the current cache to the database if possible,
  ## regardless of the save/share mode assigned to the constructor.
  ##
  ## Caveat:
  ##   If `dsc` is a detached descriptor of `Companion` or `TopShot` mode which
  ##   could be persistently saved, the changes are immediately visible on all
  ##   other descriptors unless they are hidden by newer versions of key-value
  ##   items in the cache.
  ##
  dsc.setTrackNewApi KvtPersistentFn
  result = dsc.methods.persistentFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc forget*(dsc: CoreDxKvtRef): CoreDbRc[void] {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ##
  ## This function destroys the current descriptor without any further action
  ## regardless of the save/share mode assigned to the constructor.
  ##
  ## For desciptors constructed with modes `saveMode` or`Shared`, nothing will
  ## change on the current database if there are other descriptors referring
  ## to the same shared database view. Creating a new `saveMode` or`Shared`
  ## descriptor will retrieve this state.
  ##
  ## For other desciptors constructed as `Companion` ot `TopShot`, the latest
  ## changes (after the last `persistent()` call) will be discarded.
  ##
  dsc.setTrackNewApi KvtForgetFn
  result = dsc.methods.forgetFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

iterator pairs*(kvt: CoreDxKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  kvt.setTrackNewApi KvtPairsIt
  for k,v in kvt.methods.pairsIt(): yield (k,v)
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc newMpt*(
    db: CoreDbRef;
    root: CoreDbVidRef;
    prune = true;
    saveMode = AutoSave;
      ): CoreDxMptRef =
  ## Constructor, will defect on failure. The argument `prune` is currently
  ## ignored on other than the legacy backend. The legacy backend always
  ## assumes `AutoSave` mode regardless of the function argument.
  ##
  ## See the discussion at `newKvt()` for an explanation of the `saveMode`
  ## argument.
  ##
  db.setTrackNewApi BaseNewMptFn
  result = db.methods.newMptFn(root, prune, saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, root, prune, saveMode

proc newMpt*(db: CoreDbRef; prune = true; saveMode = AutoSave): CoreDxMptRef =
  ## Shortcut for `db.newMpt CoreDbVidRef()`
  ##
  db.setTrackNewApi BaseNewMptFn
  let root = CoreDbVidRef()
  result = db.methods.newMptFn(root, prune, saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prune, saveMode

proc newMpt*(acc: CoreDxAccRef): CoreDxMptRef =
  ## Constructor, will defect on failure.
  ##
  ## Variant of `newMpt()` where the input arguments are taken from the
  ## current `acc` descriptor settings.
  ##
  acc.setTrackNewApi AccToMptFn
  result = acc.methods.newMptFn().valueOr:
    raiseAssert $$error
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc newAccMpt*(
    db: CoreDbRef;
    root: CoreDbVidRef;
    prune = true;
    saveMode = AutoSave;
      ): CoreDxAccRef =
  ## Constructor, will defect on failure. The argument `prune` is currently
  ## ignored on other than the legacy backend. The legacy backend always
  ## assumes `AutoSave` mode regardless of the function argument.
  ##
  ## This function works similar to `newMpt()` for handling accounts. Although
  ## this sub-trie can be emulated by means of `newMpt(..).toPhk()`, it is
  ## recommended using this particular constructor for accounts because it
  ## provides its own subset of methods to handle accounts.
  ##
  ## See the discussion at `newKvt()` for an explanation of the `saveMode`
  ## argument.
  ##
  db.setTrackNewApi BaseNewAccFn
  result = db.methods.newAccFn(root, prune, saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, root, prune, saveMode

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAccMpt()`.
  ##
  phk.setTrackNewApi PhkToMptFn
  result = phk.fromMpt
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAaccMpt()`.
  ##
  mpt.setTrackNewApi MptToPhkFn
  result = mpt.toCoreDxPhkRef
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc isPruning*(dsc: CoreDxTrieRefs): bool =
  ## Getter
  ##
  dsc.setTrackNewApi AnyIsPruningFn
  result = dsc.methods.isPruningFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result


proc rootVid*(acc: CoreDxAccRef): CoreDbVidRef =
  ## Getter, result is not `nil`
  ##
  acc.setTrackNewApi AccRootVidFn
  result = acc.methods.rootVidFn()
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc rootVid*(mpt: CoreDxMptRef): CoreDbVidRef =
  ## Variant of `rootVid()`
  mpt.setTrackNewApi MptRootVidFn
  result = mpt.methods.rootVidFn()
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc rootVid*(phk: CoreDxPhkRef): CoreDbVidRef =
  ## Variant of `rootVid()`
  phk.setTrackNewApi PhkRootVidFn
  result = phk.methods.rootVidFn()
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result


proc persistent*(acc: CoreDxAccRef): CoreDbRc[void] {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ## It will nevertheless return a discardable error if there is a pending
  ## transaction.
  ##
  ## This function saves the current cache to the database if possible,
  ## regardless of the save/share mode assigned to the constructor.
  ##
  ## Caveat:
  ##  If `dsc` is a detached descriptor of `Companion` or `TopShot` mode which
  ##  could be persistently saved, no changes are visible on other descriptors.
  ##  This is different from the behaviour of a `Kvt` descriptor. Saving any
  ##  other descriptor will undo the changes.
  ##
  acc.setTrackNewApi AccPersistentFn
  result = acc.methods.persistentFn()
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc persistent*(mpt: CoreDxMptRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `persistent()`
  mpt.setTrackNewApi MptPersistentFn
  result = mpt.methods.persistentFn()
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc persistent*(phk: CoreDxPhkRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `persistent()`
  phk.setTrackNewApi PhkPersistentFn
  result = phk.methods.persistentFn()
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result


proc forget*(acc: CoreDxAccRef): CoreDbRc[void] {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ##
  ## This function destroys the current descriptor without any further action
  ## regardless of the save/share mode assigned to the constructor.
  ##
  ## See the discussion at `forget()` for a `CoreDxKvtRef` type argument
  ## descriptor an explanation of how this function works.
  ##
  acc.setTrackNewApi AccForgetFn
  result = acc.methods.forgetFn()
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc forget*(mpt: CoreDxMptRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `forget()`
  mpt.setTrackNewApi MptForgetFn
  result = mpt.methods.forgetFn()
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc forget*(phk: CoreDxPhkRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `forget()`
  phk.setTrackNewApi PhkForgetFn
  result = phk.methods.forgetFn()
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `trie`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  result = mpt.methods.fetchFn key
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc fetch*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetch()"
  phk.setTrackNewApi PhkFetchFn
  result = phk.methods.fetchFn key
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result


proc fetchOrEmpty*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  result = mpt.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc fetchOrEmpty*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetchOrEmpty()`
  phk.setTrackNewApi PhkFetchOrEmptyFn
  result = phk.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result


proc delete*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  result = mpt.methods.deleteFn key
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc delete*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[void] =
  phk.setTrackNewApi PhkDeleteFn
  result = phk.methods.deleteFn key
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result


proc merge*(
    mpt: CoreDxMptRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  result = mpt.methods.mergeFn(key, val)
  mpt.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr, result

proc merge*(
    phk: CoreDxPhkRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  phk.setTrackNewApi PhkMergeFn
  result = phk.methods.mergeFn(key, val)
  phk.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr, result


proc hasPath*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  result = mpt.methods.hasPathFn key
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc hasPath*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Variant of `hasPath()`
  phk.setTrackNewApi PhkHasPathFn
  result = phk.methods.hasPathFn key
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result


iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Trie traversal, only supported for `CoreDxMptRef`
  ##
  mpt.setTrackNewApi MptPairsIt
  for k,v in mpt.methods.pairsIt(): yield (k,v)
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef`
  ##
  mpt.setTrackNewApi MptReplicateIt
  for k,v in mpt.methods.replicateIt(): yield (k,v)
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `acc`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = acc.methods.fetchFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  acc.setTrackNewApi AccDeleteFn
  result = acc.methods.deleteFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc merge*(
    acc: CoreDxAccRef;
    address: EthAddress;
    account: CoreDbAccount;
      ): CoreDbRc[void] =
  acc.setTrackNewApi AccMergeFn
  result = acc.methods.mergeFn(address, account)
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc hasPath*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi AccHasPathFn
  result = acc.methods.hasPathFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  ##
  db.setTrackNewApi BaseNewTxFn
  result = db.methods.beginFn()
  db.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, newLevel=db.methods.levelFn(), result

proc level*(tx: CoreDxTxRef): int =
  ## Print positive argument `tx` transaction level
  ##
  tx.setTrackNewApi TxLevelFn
  result = tx.methods.levelFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc commit*(tx: CoreDxTxRef, applyDeletes = true): CoreDbRc[void] =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.commitFn applyDeletes
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc rollback*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.rollbackFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc dispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.disposeFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc safeDispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxSaveDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.safeDisposeFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc newCapture*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbRc[CoreDxCaptRef] =
  ## Constructor
  db.setTrackNewApi BaseCaptureFn
  result = db.methods.captureFn flags
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc recorder*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  ## Getter
  cp.setTrackNewApi CptRecorderFn
  result = cp.methods.recorderFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc logDb*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  cp.setTrackNewApi CptLogDbFn
  result = cp.methods.logDbFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc flags*(cp: CoreDxCaptRef): set[CoreDbCaptFlags] =
  ## Getter
  cp.setTrackNewApi CptFlagsFn
  result = cp.methods.getFlagsFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# Public methods, legacy API
# ------------------------------------------------------------------------------

when ProvideLegacyAPI:

  proc parent*(cld: CoreDbChldRefs): CoreDbRef =
    ## Getter, common method for all sub-modules
    result = cld.distinctBase.parent

  proc backend*(dsc: CoreDbChldRefs): auto =
    dsc.setTrackLegaApi LegaBackendFn
    result = dsc.distinctBase.backend
    dsc.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.setTrackLegaApi LegaNewKvtFn
    result = db.newKvt().CoreDbKvtRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.setTrackLegaApi LegaKvtGetFn
    result = kvt.distinctBase.getOrEmpty(key).expect $ctx
    kvt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, result=result.toStr

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.setTrackLegaApi LegaKvtDelFn
    kvt.distinctBase.del(key).expect $ctx
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr

  proc put*(kvt: CoreDbKvtRef; key: openArray[byte]; val: openArray[byte]) =
    kvt.setTrackLegaApi LegaKvtPutFn
    kvt.distinctBase.parent.newKvt().put(key, val).expect $ctx
    kvt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.setTrackLegaApi LegaKvtContainsFn
    result = kvt.distinctBase.hasKey(key).expect $ctx
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr, result

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    kvt.setTrackLegaApi LegaKvtPairsIt
    for k,v in kvt.distinctBase.pairs(): yield (k,v)
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.setTrackLegaApi LegaToMptFn
    result = phk.distinctBase.toMpt.CoreDbMptRef
    phk.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    db.setTrackLegaApi LegaNewMptFn
    let vid = db.getRoot(root, createOk=true).expect $ctx
    result = db.newMpt(vid, prune).CoreDbMptRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, root=root.toStr, prune

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.newMpt(CoreDbVidRef(nil), prune).CoreDbMptRef

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.setTrackLegaApi LegaToPhkFn
    result = mpt.distinctBase.toPhk.CoreDbPhkRef
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    db.setTrackLegaApi LegaNewPhkFn
    let vid = db.getRoot(root, createOk=true).expect $ctx
    result = db.newMpt(vid, prune).toCoreDxPhkRef.CoreDbPhkRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, root=root.toStr, prune

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.newMpt(CoreDbVidRef(nil), prune).toCoreDxPhkRef.CoreDbPhkRef

  # ----------------

  proc isPruning*(trie: CoreDbTrieRefs): bool =
    trie.setTrackLegaApi LegaIsPruningFn
    result = trie.distinctBase.isPruning()
    trie.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result


  proc get*(mpt: CoreDbMptRef; key: openArray[byte]): Blob =
    mpt.setTrackLegaApi LegaMptGetFn
    result = mpt.distinctBase.fetchOrEmpty(key).expect $ctx
    mpt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, result=result.toStr

  proc get*(phk: CoreDbPhkRef; key: openArray[byte]): Blob =
    phk.setTrackLegaApi LegaPhkGetFn
    result = phk.distinctBase.fetchOrEmpty(key).expect $ctx
    phk.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, result=result.toStr


  proc del*(mpt: CoreDbMptRef; key: openArray[byte]) =
    mpt.setTrackLegaApi LegaMptDelFn
    mpt.distinctBase.delete(key).expect $ctx
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr

  proc del*(phk: CoreDbPhkRef; key: openArray[byte]) =
    phk.setTrackLegaApi LegaPhkDelFn
    phk.distinctBase.delete(key).expect $ctx
    phk.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr


  proc put*(mpt: CoreDbMptRef; key: openArray[byte]; val: openArray[byte]) =
    mpt.setTrackLegaApi LegaMptPutFn
    mpt.distinctBase.merge(key, val).expect $ctx
    mpt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr

  proc put*(phk: CoreDbPhkRef; key: openArray[byte]; val: openArray[byte]) =
    phk.setTrackLegaApi LegaPhkPutFn
    phk.distinctBase.merge(key, val).expect $ctx
    phk.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr


  proc contains*(mpt: CoreDbMptRef; key: openArray[byte]): bool =
    mpt.setTrackLegaApi LegaMptContainsFn
    result = mpt.distinctBase.hasPath(key).expect $ctx
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr, result

  proc contains*(phk: CoreDbPhkRef; key: openArray[byte]): bool =
    phk.setTrackLegaApi LegaPhkContainsFn
    result = phk.distinctBase.hasPath(key).expect $ctx
    phk.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr, result


  proc rootHash*(mpt: CoreDbMptRef): Hash256 =
    mpt.setTrackLegaApi LegaMptRootHashFn
    result = mpt.distinctBase.rootVid().hash(update=true).expect $ctx
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result=result.toStr

  proc rootHash*(phk: CoreDbPhkRef): Hash256 =
    phk.setTrackLegaApi LegaPhkRootHashFn
    result = phk.distinctBase.rootVid().hash(update=true).expect $ctx
    phk.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result=result.toStr


  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Trie traversal, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi LegaMptPairsIt
    for k,v in mpt.distinctBase.pairs(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi LegaMptReplicateIt
    for k,v in mpt.distinctBase.replicate(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    db.setTrackLegaApi LegaGetTxIdFn
    result = db.methods.getIdFn().expect($ctx).CoreDbTxID
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc shortTimeReadOnly*(
      id: CoreDbTxID;
      action: proc() {.catchRaise.};
        ) {.catchRaise.} =
    id.setTrackLegaApi LegaShortTimeRoFn
    var oops = none(ref CatchableError)
    proc safeFn() =
      try:
        action()
      except CatchableError as e:
        oops = some(e)
      # Action has finished now

    id.distinctBase.methods.roWrapperFn(safeFn).expect $ctx

    # Delayed exception
    if oops.isSome:
      let
        e = oops.unsafeGet
        msg = "delayed and reraised" &
          ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
      raise (ref TxWrapperApiError)(msg: msg)
    id.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
    db.setTrackLegaApi LegaBeginTxFn
    result = (db.distinctBase.methods.beginFn().expect $ctx).CoreDbTxRef
    db.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, newLevel=db.methods.levelFn()

  proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
    tx.setTrackLegaApi LegaTxCommitFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.commit(applyDeletes).expect $ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc rollback*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxCommitFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.rollback().expect $ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc dispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxDisposeFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.dispose().expect $ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc safeDispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxSaveDisposeFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.safeDispose().expect $ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  # ----------------

  proc capture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbCaptRef =
    db.setTrackLegaApi LegaCaptureFn
    result = db.newCapture(flags).expect($ctx).CoreDbCaptRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc recorder*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApi LegaCptRecorderFn
    result = cp.distinctBase.recorder().expect $ctx
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc logDb*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApi LegaCptLogDbFn
    result = cp.distinctBase.logDb().expect $ctx
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc flags*(cp: CoreDbCaptRef): set[CoreDbCaptFlags] =
    cp.setTrackLegaApi LegaCptFlagsFn
    result = cp.distinctBase.flags()
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
