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
  ./base/[api_new_desc, api_tracking, base_desc, validate]

export
  CoreDbAccBackendRef,
  CoreDbAccount,
  CoreDbApiError,
  CoreDbBackendRef,
  CoreDbCaptFlags,
  CoreDbErrorCode,
  CoreDbErrorRef,
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
  CoreDxTxRef

const
  ProvideCoreDbLegacyAPI* = true # and false

when ProvideCoreDbLegacyAPI:
  import
    base/api_legacy_desc
  export
    api_legacy_desc


# More settings
const
  AutoValidateDescriptors = defined(release).not

  EnableApiTracking = true and false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Tracking is enabled by setting to `true` the
    ## flags `trackLegaApi` and/or `trackNewApi` in the `CoreDxTxRef`
    ## descriptor.

  logTxt = "CoreDb "

  legaApiTxt* = logTxt & "legacy API"

  newApiTxt* = logTxt & "new API"

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
  {.warning: "*** Provided API logging for CoreDB (disabled by default)".}

  import
    std/[sequtils, strutils, times]

  proc `$`[T](rc: CoreDbRc[T]): string = rc.toStr
  proc `$`(q: set[CoreDbCaptFlags]): string = q.toStr
  proc `$`(t: Duration): string = t.toStr
  proc `$`(e: EthAddress): string = e.toStr
  proc `$`(v: CoreDbVidRef): string = v.toStr

when ProvideCoreDbLegacyAPI:
  when EnableApiTracking:
    proc `$`(k: CoreDbKvtRef): string = k.toStr

  template getTrackLegaCtx(
      w: CoreDbApiTrackRef;
      s: static[string];
        ): string =
    ## Explicit `let ctx = ..` statement is needed for generic functions
    ## when the argument `ctx` is used outside the log templates as in the
    ## expression `...expect(ctx)`.
    when EnableApiTracking:
      w.beginLegaApi()
    w.legaApiCtx(s)

  template setTrackLegaApi(
      w: CoreDbApiTrackRef;
      s: static[string];
        ) =
    when EnableApiTracking:
      w.beginLegaApi()
    let ctx {.inject,used.} = w.legaApiCtx(s)

  template setTrackLegaApi(
      w: CoreDbApiTrackRef;
      s: static[string];
      code: untyped;
        ) =
    ## Like `setTrackNewApi()`, with code section that will be discarded if
    ## logging is disabled at compile time when `EnableApiTracking` is `false`.
    when EnableApiTracking:
      w.beginLegaApi()
      code
    let ctx {.inject,used.} = w.legaApiCtx(s)


  template ifTrackLegaApi(w: CoreDbApiTrackRef; code: untyped) =
    when EnableApiTracking:
      w.endLegaApiIf:
        code


template setTrackNewApi(
    w: CoreDxApiTrackRef;
    s: static[string];
      ) =
  when EnableApiTracking:
    w.beginNewApi()
  let ctx {.inject,used.} = w.newApiCtx(s)

template setTrackNewApi(
    w: CoreDxApiTrackRef;
    s: static[string];
    code: untyped;
      ) =
  ## Like `setTrackNewApi()`, with code section that will be discarded if
  ## logging is disabled at compile time when `EnableApiTracking` is `false`.
  when EnableApiTracking:
    w.beginNewApi()
    code
  let ctx {.inject,used.} = w.newApiCtx(s)


template ifTrackNewApi(w: CoreDxApiTrackRef; code: untyped) =
  when EnableApiTracking:
    w.endNewApiIf:
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
  db.setTrackNewApi "dbType()"
  result = db.dbType
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc compensateLegacySetup*(db: CoreDbRef) =
  ## On the persistent legacy hexary trie, this function is needed for
  ## bootstrapping and Genesis setup when the `purge` flag is activated.
  ## Otherwise the database backend may defect on an internal inconsistency.
  ##
  db.setTrackNewApi "compensateLegacySetup()"
  db.methods.legacySetupFn()
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc level*(db: CoreDbRef): int =
  ## Print transaction level, zero if there is no pending transaction
  ##
  db.setTrackNewApi "level()"
  result = db.methods.levelFn()
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc parent*(cld: CoreDxChldRefs): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = cld.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxTrieRelated | CoreDbRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  dsc.setTrackNewApi "backend()"
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
  db.setTracknewApi "finish()"
  db.methods.destroyFn flush
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc `$$`*(e: CoreDbErrorRef): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  ##
  e.setTrackNewApi "$$()"
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
  vid.setTrackNewApi "hash()"
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
  vid.setTrackNewApi "recast()"
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
  db.setTrackNewApi "getRoot()"
  result = db.methods.getRootFn(root, createOk)
  db.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, root=root.toStr, result

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
  db.setTrackNewApi "newKvt()"
  result = db.methods.newKvtFn(saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, saveMode

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function always returns a non-empty `Blob` or an error code.
  kvt.setTrackNewApi "get()"
  result = kvt.methods.getFn key
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc getOrEmpty*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function sort of mimics the behaviour of the legacy database
  ## returning an empty `Blob` if the argument `key` is not found on the
  ## database.
  ##
  kvt.setTrackNewApi "getOrEmpty()"
  result = kvt.methods.getFn key
  if result.isErr and result.error.error == KvtNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc del*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.setTrackNewApi "del()"
  result = kvt.methods.delFn key
  kvt.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc put*(
    kvt: CoreDxKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  kvt.setTrackNewApi "put()"
  result = kvt.methods.putFn(key, val)
  kvt.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr, result

proc hasKey*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  kvt.setTrackNewApi "hasKey()"
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
  dsc.setTrackNewApi "persistent()"
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
  dsc.setTrackNewApi "forget()"
  result = dsc.methods.forgetFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

iterator pairs*(kvt: CoreDxKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  kvt.setTrackNewApi "pairs()"
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
  db.setTrackNewApi "newMpt()"
  result = db.methods.newMptFn(root, prune, saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, root, prune, saveMode

proc newMpt*(db: CoreDbRef; prune = true; saveMode = AutoSave): CoreDxMptRef =
  ## Shortcut for `db.newMpt CoreDbVidRef()`
  ##
  db.setTrackNewApi "newMpt()"
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
  acc.setTrackNewApi "toMpt()"
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
  db.setTrackNewApi "newAccMpt()"
  result = db.methods.newAccFn(root, prune, saveMode).valueOr:
    raiseAssert $$error
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, root, prune, saveMode

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAccMpt()`.
  ##
  phk.setTrackNewApi "toMpt()"
  result = phk.fromMpt
  phk.ifTrackNewApi: debug newApiTxt, ctx, elapsed

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAaccMpt()`.
  ##
  mpt.setTrackNewApi "toPhk()"
  result = mpt.toCoreDxPhkRef
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc isPruning*(dsc: CoreDxTrieRefs | CoreDxAccRef): bool =
  ## Getter
  ##
  dsc.setTrackNewApi "isPruning()"
  result = dsc.methods.isPruningFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc rootVid*(dsc: CoreDxTrieRefs | CoreDxAccRef): CoreDbVidRef =
  ## Getter, result is not `nil`
  ##
  dsc.setTrackNewApi "rootVid()"
  result = dsc.methods.rootVidFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result=result.toStr

proc persistent*(
    dsc: CoreDxTrieRefs | CoreDxAccRef;
      ): CoreDbRc[void]
      {.discardable.} =
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
  dsc.setTrackNewApi "persistent()"
  result = dsc.methods.persistentFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc forget*(
    dsc: CoreDxTrieRefs | CoreDxAccRef;
      ): CoreDbRc[void]
      {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ##
  ## This function destroys the current descriptor without any further action
  ## regardless of the save/share mode assigned to the constructor.
  ##
  ## See the discussion at `forget()` for a `CoreDxKvtRef` type argument
  ## descriptor an explanation of how this function works.
  ##
  dsc.setTrackNewApi "forget()"
  result = dsc.methods.forgetFn()
  dsc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `trie`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  trie.setTrackNewApi "fetch()"
  result = trie.methods.fetchFn key
  trie.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc fetchOrEmpty*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  trie.setTrackNewApi "fetchOrEmpty()"
  result = trie.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = ok(EmptyBlob)
  trie.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc delete*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[void] =
  trie.setTrackNewApi "delete()"
  result = trie.methods.deleteFn key
  trie.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

proc merge*(
    trie: CoreDxTrieRefs;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  trie.setTrackNewApi "merge()"
  result = trie.methods.mergeFn(key, val)
  trie.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr, result

proc hasPath*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  trie.setTrackNewApi "hasPath()"
  result = trie.methods.hasPathFn key
  trie.ifTrackNewApi: debug newApiTxt, ctx, elapsed, key=key.toStr, result

iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Trie traversal, only supported for `CoreDxMptRef`
  ##
  mpt.setTrackNewApi "pairs()"
  for k,v in mpt.methods.pairsIt(): yield (k,v)
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef`
  ##
  mpt.setTrackNewApi "replicate()"
  for k,v in mpt.methods.replicateIt(): yield (k,v)
  mpt.ifTrackNewApi: debug newApiTxt, ctx, elapsed

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `trie`.
  ##
  acc.setTrackNewApi "fetch()"
  result = acc.methods.fetchFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  acc.setTrackNewApi "delete()"
  result = acc.methods.deleteFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc merge*(
    acc: CoreDxAccRef;
    address: EthAddress;
    account: CoreDbAccount;
      ): CoreDbRc[void] =
  acc.setTrackNewApi "merge()"
  result = acc.methods.mergeFn(address, account)
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

proc hasPath*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[bool] =
  ## Would be named `contains` if it returned `bool` rather than `Result[]`.
  ##
  acc.setTrackNewApi "hasPath()"
  result = acc.methods.hasPathFn address
  acc.ifTrackNewApi: debug newApiTxt, ctx, elapsed, address, result

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  ##
  db.setTrackNewApi "newTransaction()"
  result = db.methods.beginFn()
  db.ifTrackNewApi:
    debug newApiTxt, ctx, elapsed, newLevel=db.methods.levelFn(), result

proc level*(tx: CoreDxTxRef): int =
  ## Print positive argument `tx` transaction level
  ##
  tx.setTrackNewApi "level()"
  result = tx.methods.levelFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc commit*(tx: CoreDxTxRef, applyDeletes = true): CoreDbRc[void] =
  tx.setTrackNewApi "commit()":
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.commitFn applyDeletes
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc rollback*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi "rollback()":
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.rollbackFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc dispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi "dispose()":
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.disposeFn()
  tx.ifTrackNewApi: debug newApiTxt, ctx, elapsed, prvLevel, result

proc safeDispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi "safeDispose()":
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
  db.setTrackNewApi "capture()"
  result = db.methods.captureFn flags
  db.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc recorder*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  ## Getter
  cp.setTrackNewApi "recorder()"
  result = cp.methods.recorderFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc logDb*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  cp.setTrackNewApi "logDb()"
  result = cp.methods.logDbFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

proc flags*(cp: CoreDxCaptRef): set[CoreDbCaptFlags] =
  ## Getter
  cp.setTrackNewApi "flags()"
  result = cp.methods.getFlagsFn()
  cp.ifTrackNewApi: debug newApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# Public methods, legacy API
# ------------------------------------------------------------------------------

when ProvideCoreDbLegacyAPI:

  proc parent*(cld: CoreDbChldRefs): CoreDbRef =
    ## Getter, common method for all sub-modules
    result = cld.distinctBase.parent

  proc backend*(dsc: CoreDbChldRefs): auto =
    dsc.setTrackLegaApi "parent()"
    result = dsc.distinctBase.backend
    dsc.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.setTrackLegaApi "kvt()"
    result = db.newKvt().CoreDbKvtRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.setTrackLegaApi "get()"
    result = kvt.distinctBase.getOrEmpty(key).expect ctx
    kvt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, result=result.toStr

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.setTrackLegaApi "del()"
    kvt.distinctBase.del(key).expect ctx
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr

  proc put*(kvt: CoreDbKvtRef; key: openArray[byte]; val: openArray[byte]) =
    kvt.setTrackLegaApi "kvt/put()"
    kvt.distinctBase.parent.newKvt().put(key, val).expect ctx
    kvt.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.setTrackLegaApi "contains()"
    result = kvt.distinctBase.hasKey(key).expect ctx
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr, result

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    kvt.setTrackLegaApi "pairs()"
    for k,v in kvt.distinctBase.pairs(): yield (k,v)
    kvt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.setTrackLegaApi "phk/toMpt()"
    result = phk.distinctBase.toMpt.CoreDbMptRef
    phk.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    db.setTrackLegaApi "mptPrune()"
    let vid = db.getRoot(root, createOk=true).expect ctx
    result = db.newMpt(vid, prune).CoreDbMptRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, root=root.toStr, prune

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.newMpt(CoreDbVidRef(nil), prune).CoreDbMptRef

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.setTrackLegaApi "toMpt()"
    result = mpt.distinctBase.toPhk.CoreDbPhkRef
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    db.setTrackLegaApi "phkPrune()"
    let vid = db.getRoot(root, createOk=true).expect ctx
    result = db.newMpt(vid, prune).toCoreDxPhkRef.CoreDbPhkRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, root=root.toStr, prune

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.newMpt(CoreDbVidRef(nil), prune).toCoreDxPhkRef.CoreDbPhkRef

  # ----------------

  proc isPruning*(trie: CoreDbTrieRefs): bool =
    trie.setTrackLegaApi "isPruning()"
    result = trie.distinctBase.isPruning()
    trie.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result

  proc get*(trie: CoreDbTrieRefs; key: openArray[byte]): Blob =
    let ctx = trie.getTrackLegaCtx "get()"
    result = trie.distinctBase.fetchOrEmpty(key).expect ctx
    trie.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, result=result.toStr

  proc del*(trie: CoreDbTrieRefs; key: openArray[byte]) =
    let ctx = trie.getTrackLegaCtx "del()"
    trie.distinctBase.delete(key).expect ctx
    trie.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr

  proc put*(trie: CoreDbTrieRefs; key: openArray[byte]; val: openArray[byte]) =
    let ctx = trie.getTrackLegaCtx "put()"
    trie.distinctBase.merge(key, val).expect ctx
    trie.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, key=key.toStr, val=val.toSeq.toStr

  proc contains*(trie: CoreDbTrieRefs; key: openArray[byte]): bool =
    let ctx = trie.getTrackLegaCtx "contains()"
    result = trie.distinctBase.hasPath(key).expect ctx
    trie.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, key=key.toStr, result

  proc rootHash*(trie: CoreDbTrieRefs): Hash256 =
    let ctx = trie.getTrackLegaCtx "rootHash()"
    result = trie.distinctBase.rootVid().hash(update=true).expect ctx
    trie.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result=result.toStr

  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Trie traversal, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi "pairs()"
    for k,v in mpt.distinctBase.pairs(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApi "replicate()"
    for k,v in mpt.distinctBase.replicate(): yield (k,v)
    mpt.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    db.setTrackLegaApi "getTransactionID()"
    result = db.methods.getIdFn().expect(ctx).CoreDbTxID
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc shortTimeReadOnly*(
      id: CoreDbTxID;
      action: proc() {.catchRaise.};
        ) {.catchRaise.} =
    id.setTrackLegaApi "shortTimeReadOnly()"
    var oops = none(ref CatchableError)
    proc safeFn() =
      try:
        action()
      except CatchableError as e:
        oops = some(e)
      # Action has finished now

    id.distinctBase.methods.roWrapperFn(safeFn).expect ctx

    # Delayed exception
    if oops.isSome:
      let
        e = oops.unsafeGet
        msg = "delayed and reraised" &
          ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
      raise (ref TxWrapperApiError)(msg: msg)
    id.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
    db.setTrackLegaApi "beginTransaction()"
    result = (db.distinctBase.methods.beginFn().expect ctx).CoreDbTxRef
    db.ifTrackLegaApi:
      debug legaApiTxt, ctx, elapsed, newLevel=db.methods.levelFn()

  proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
    tx.setTrackLegaApi "commit()":
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.commit(applyDeletes).expect ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc rollback*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi "rollback()":
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.rollback().expect ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc dispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi "dispose()":
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.dispose().expect ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  proc safeDispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi "safeDispose()":
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.safeDispose().expect ctx
    tx.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, prvLevel

  # ----------------

  proc capture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbCaptRef =
    db.setTrackLegaApi "capture()"
    result = db.newCapture(flags).expect(ctx).CoreDbCaptRef
    db.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc recorder*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApi "recorder()"
    result = cp.distinctBase.recorder().expect ctx
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc logDb*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApi "logDb()"
    result = cp.distinctBase.logDb().expect ctx
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed

  proc flags*(cp: CoreDbCaptRef): set[CoreDbCaptFlags] =
    cp.setTrackLegaApi "flags()"
    result = cp.distinctBase.flags()
    cp.ifTrackLegaApi: debug legaApiTxt, ctx, elapsed, result

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
