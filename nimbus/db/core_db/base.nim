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
  results,
  "../.."/[constants, errors],
  ./base/[api_new_desc, api_tracking, base_desc]

from ../aristo
  import EmptyBlob, isValid

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
  CoreDbProfListRef,
  CoreDbRef,
  CoreDbSubTrie,
  CoreDbTrieRef,
  CoreDbType,
  CoreDxAccRef,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxRef

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

# More settings
const
  logTxt = "CoreDb "
  legaApiTxt = logTxt & "legacy API"
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
  proc `$`(v: CoreDbTrieRef): string = v.toStr
  proc `$`(h: Hash256): string = h.toStr
  proc `$`(b: Blob): string = b.toLenStr

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
      w.beginLegaApi(s)
      code
    const api {.inject,used.} = s

  template setTrackLegaApi*(
      w: CoreDbApiTrackRef;
      s: static[CoreDbFnInx];
        ) =
    w.setTrackLegaApi(s):
      discard

  template ifTrackLegaApi*(w: CoreDbApiTrackRef; code: untyped) =
    when EnableApiTracking:
      w.endLegaApiIf:
        code


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
  when CoreDbEnableApiProfiling:
    db.profTab = CoreDbProfListRef.init()
  db

proc bless*(db: CoreDbRef; trie: CoreDbTrieRef): CoreDbTrieRef =
  ## Complete sub-module descriptor, fill in `parent` and actvate it.
  trie.parent = db
  trie.ready = true
  when AutoValidateDescriptors:
    trie.validate
  trie

proc bless*(db: CoreDbRef; kvt: CoreDxKvtRef): CoreDxKvtRef =
  ## Complete sub-module descriptor, fill in `parent`.
  kvt.parent = db
  when AutoValidateDescriptors:
    kvt.validate
  kvt

proc bless*[T: CoreDxTrieRelated | CoreDbBackends](
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

proc prettyText*(trie: CoreDbTrieRef): string =
  ## Pretty print argument object (for tracking use `$$()`)
  if trie.isNil or not trie.ready: "$ø" else: trie.toStr()

proc verify*(trie: CoreDbTrieRef): bool =
  ## Verify that the `trie` argument is `nil` or properly initialised. This
  ## function is for debugging and subject to change.
  trie.isNil or (trie.ready and trie.parent.methods.verifyFn trie)

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

proc compensateLegacySetup*(db: CoreDbRef) =
  ## On the persistent legacy hexary trie, this function is needed for
  ## bootstrapping and Genesis setup when the `purge` flag is activated.
  ## Otherwise the database backend may defect on an internal inconsistency.
  ##
  db.setTrackNewApi BaseLegacySetupFn
  db.methods.legacySetupFn()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed

proc level*(db: CoreDbRef): int =
  ## Getter, retrieve transaction level (zero if there is no pending
  ## transaction)
  ##
  db.setTrackNewApi BaseLevelFn
  result = db.methods.levelFn()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc parent*(cld: CoreDxChldRefs): CoreDbRef =
  ## Getter, common method for all sub-modules
  ##
  result = cld.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxTrieRelated | CoreDbRef): auto =
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

proc `$$`*(trie: CoreDbTrieRef): string =
  ## Pretty print vertex ID symbol, note that this directive may have side
  ## effects as it calls a backend function.
  ##
  #trie.setTrackNewApi TriePrintFn
  result = trie.prettyText()
  #trie.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc rootHash*(trie: CoreDbTrieRef): CoreDbRc[Hash256] =
  ## Getter (well, sort of), retrieves the root hash for the argument `trie`
  ## descriptor. The function might fail if there is currently no hash
  ## available (e.g. on `Aristo`.) Note that a failure to retrieve the hash
  ## (which returns an error) is different from succeeding with an
  ## `EMPTY_ROOT_HASH` value for an empty trie.
  ##
  ## The value `EMPTY_ROOT_HASH` is also returned on a void `trie` descriptor
  ## argument `CoreDbTrieRef(nil)`.
  ##
  trie.setTrackNewApi RootHashFn
  result = block:
    if not trie.isNil and trie.ready:
      trie.parent.methods.rootHashFn trie
    else:
      ok EMPTY_ROOT_HASH
  # Note: tracker will be silent if `vid` is NIL
  trie.ifTrackNewApi: debug newApiTxt, api, elapsed, trie, result

proc rootHashOrEmpty*(trie: CoreDbTrieRef): Hash256 =
  ## Convenience wrapper, returns `EMPTY_ROOT_HASH` where `hash()` would fail.
  trie.rootHash.valueOr: EMPTY_ROOT_HASH

proc recast*(account: CoreDbAccount): CoreDbRc[Account] =
  ## Convert the argument `account` to the portable Ethereum representation
  ## of an account. This conversion may fail if the storage root hash (see
  ## `hash()` above) is currently unavailable.
  ##
  ## Note that for the legacy backend, this function always succeeds.
  ##
  let stoTrie = account.stoTrie
  stoTrie.setTrackNewApi EthAccRecastFn
  let rc =
    if stoTrie.isNil or not stoTrie.ready: CoreDbRc[Hash256].ok(EMPTY_ROOT_HASH)
    else: stoTrie.parent.methods.rootHashFn stoTrie
  result =
    if rc.isOk:
      ok Account(
        nonce:       account.nonce,
        balance:     account.balance,
        codeHash:    account.codeHash,
        storageRoot: rc.value)
    else:
      err(rc.error)
  stoTrie.ifTrackNewApi: debug newApiTxt, api, elapsed, stoTrie, result


proc getTrie*(
    db: CoreDbRef;
    kind: CoreDbSubTrie;
    root: Hash256;
    address = none(EthAddress);
      ): CoreDbRc[CoreDbTrieRef] =
  ## Retrieve virtual sub-trie descriptor.
  ##
  ## For a sub-trie of type `kind` find the root node with Merkle hash `root`.
  ## If the `root` argument is set `EMPTY_ROOT_HASH`, this function always
  ## succeeds. Otherwise, the function will fail unless a root node with the
  ## corresponding argument Merkle hash `root` exists.
  ##
  ## For an `EMPTY_ROOT_HASH` root hash argument and a sub-trie of type `kind`
  ## different form `StorageTrie` and `AccuntsTrie`, the returned sub-trie
  ## descriptor will be flagged to flush the sub-trie when this descriptor is
  ## incarnated as MPT (see `newMpt()`.).
  ##
  ## If the argument `kind` is `StorageTrie`, then the `address` argument is
  ## needed which links an account to the result descriptor.
  ##
  ## This function is intended to open a virtual trie database as in:
  ## ::
  ##   proc openAccountLedger(db: CoreDbRef, root: Hash256): CoreDxMptRef =
  ##     let trie = db.getTrie(AccountsTrie, root).valueOr:
  ##       # some error handling
  ##       return
  ##     db.newAccMpt trie
  ##
  db.setTrackNewApi BaseGetTrieFn
  result = db.methods.getTrieFn(kind, root, address)
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, kind, root, address, result

proc getTrie*(
    db: CoreDbRef;
    root: Hash256;
    address: EthAddress;
      ): CoreDbRc[CoreDbTrieRef] =
  ## Shortcut for `db.getTrie(StorageTrie,root,some(address))`.
  ##
  db.setTrackNewApi BaseGetTrieFn
  result = db.methods.getTrieFn(StorageTrie, root, some(address))
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, root, address, result

proc getTrie*(
    db: CoreDbRef;
    address: EthAddress;
      ): CoreDbTrieRef =
  ## Shortcut for `db.getTrie(StorageTrie,EMPTY_ROOT_HASH,address).value`. The
  ## function will throw an exception on error. So the result will always be a
  ## valid descriptor.
  ##
  db.setTrackNewApi BaseGetTrieFn
  result = db.methods.getTrieFn(
             StorageTrie, EMPTY_ROOT_HASH, some(address)).valueOr:
    raiseAssert error.prettyText()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc newKvt*(db: CoreDbRef; sharedTable = true): CoreDxKvtRef =
  ## Constructor, will defect on failure.
  ##
  ## Depending on the argument `sharedTable`, the contructed object will have
  ## the following properties.
  ##
  ## * `true`
  ##   Subscribe to the common base object shared with other shared
  ##   descriptors. Any changes are immediately visible among subscribers.
  ##   On destruction (when the constructed object gets out of scope), changes
  ##   are not saved to the backend database but are still available to
  ##   other subscribers.
  ##
  ## * `false`
  ##   The contructed object will be a new separate descriptor with a clean
  ##   cache and no pending transactions. On automatic destruction, changes
  ##   will be discarded.
  ##
  db.setTrackNewApi BaseNewKvtFn
  result = db.methods.newKvtFn(sharedTable).valueOr:
    raiseAssert error.prettyText()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, sharedTable

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
  dsc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc forget*(dsc: CoreDxKvtRef): CoreDbRc[void] {.discardable.} =
  ## For the legacy database, this function has no effect and succeeds always.
  ##
  ## This function destroys the current non-shared descriptor (see argument
  ## `sharedTable` for `newKvt()`) regardless of the save/share mode
  ## assigned to the constructor. For other descriptor types, the function
  ## does nothing.
  ##
  ## Note:
  ##   Auto destruction seems to be unreliable (causing spurious crashes.)
  ##   So manual destruction using this function is advised.
  ##
  dsc.setTrackNewApi KvtForgetFn
  result = dsc.methods.forgetFn()
  dsc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc newMpt*(
    db: CoreDbRef;
    trie: CoreDbTrieRef;
    prune = true;
      ): CoreDbRc[CoreDxMptRef] =
  ## MPT sub-trie object incarnation. The argument `prune` is currently
  ## ignored on other than the legacy backend. The legacy backend always
  ## assumes `AutoSave` mode regardless of the function argument.
  ##
  ## If the `trie` argument was created for an `EMPTY_ROOT_HASH` sub-trie, the
  ## sub-trie database will be flushed. There is no need to keep the `trie`
  ## argument. It can always be rerieved for this particular incarnation unsing
  ## the function `getTrie()` on this MPT.
  ##
  db.setTrackNewApi BaseNewMptFn
  result = db.methods.newMptFn(trie, prune)
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, trie, prune, result

proc newMpt*(
    db: CoreDbRef;
    kind: CoreDbSubTrie;
    address = none(EthAddress);
    prune = true;
      ): CoreDxMptRef =
  ## Shortcut for `newMpt(trie,prune)` where the `trie` argument is
  ## `db.getTrie(kind,EMPTY_ROOT_HASH).value`. This function will always
  ## return a non-nil descriptor or throw an exception.
  ##
  db.setTrackNewApi BaseNewMptFn
  let trie = db.methods.getTrieFn(kind, EMPTY_ROOT_HASH, address).value
  result = db.methods.newMptFn(trie, prune).valueOr:
    raiseAssert error.prettyText()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, prune


proc newMpt*(acc: CoreDxAccRef): CoreDxMptRef =
  ## Constructor, will defect on failure.
  ##
  ## Variant of `newMpt()` where the input arguments are taken from the
  ## current `acc` descriptor settings.
  ##
  acc.setTrackNewApi AccToMptFn
  result = acc.methods.newMptFn().valueOr:
    raiseAssert error.prettyText()
  acc.ifTrackNewApi:
    let root = result.methods.getTrieFn()
    debug newApiTxt, api, elapsed, root


proc newAccMpt*(
    db: CoreDbRef;
    trie: CoreDbTrieRef;
    prune = true;
      ): CoreDbRc[CoreDxAccRef] =
  ## Accounts trie constructor, will defect on failure. The argument `prune`
  ## is currently ignored on other than the legacy backend.
  ##
  ## Example:
  ## ::
  ##   let trie = db.getTrie(AccountsTrie,<some-hash>).valueOr:
  ##     ... # No node with <some-hash>
  ##     return
  ##
  ##   let acc = db.newAccMpt(trie)
  ##     ... # Was not the state root for the accounts sub-trie
  ##     return
  ##
  ## This function works similar to `newMpt()` for handling accounts. Although
  ## this sub-trie can be emulated by means of `newMpt(..).toPhk()`, it is
  ## recommended using this particular constructor for accounts because it
  ## provides its own subset of methods to handle accounts.
  ##
  db.setTrackNewApi BaseNewAccFn
  result = db.methods.newAccFn(trie, prune)
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, trie, prune, result

proc newAccMpt*(
    db: CoreDbRef;
    root = EMPTY_ROOT_HASH;
    prune = true;
      ): CoreDxAccRef =
  ## Simplified version of `newAccMpt()` where the `CoreDbTrieRef` argument is
  ## replaced by a `root` hash argument. This function is sort of a shortcut
  ## for:
  ## ::
  ##   let trie = db.getTrie(AccountsTrie, root).value
  ##   result = db.newAccMpt(trie, prune).value
  ##
  ## and will throw an exception if something goes wrong. The result reference
  ## will alwye be non `nil`.
  ##
  db.setTrackNewApi BaseNewAccFn
  let trie = db.methods.getTrieFn(AccountsTrie, root, none(EthAddress)).valueOr:
    raiseAssert error.prettyText()
  result = db.methods.newAccFn(trie, prune).valueOr:
    raiseAssert error.prettyText()
  db.ifTrackNewApi: debug newApiTxt, api, elapsed, prune


proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAccMpt()`.
  ##
  phk.setTrackNewApi PhkToMptFn
  result = phk.fromMpt
  phk.ifTrackNewApi:
    let trie = result.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAaccMpt()`.
  ##
  mpt.setTrackNewApi MptToPhkFn
  result = mpt.toCoreDxPhkRef
  mpt.ifTrackNewApi:
    let trie = result.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc isPruning*(dsc: CoreDxTrieRefs): bool =
  ## Getter
  ##
  dsc.setTrackNewApi AnyIsPruningFn
  result = dsc.methods.isPruningFn()
  dsc.ifTrackNewApi: debug newApiTxt, api, elapsed, result


proc getTrie*(acc: CoreDxAccRef): CoreDbTrieRef =
  ## Getter, result is not `nil`
  ##
  acc.setTrackNewApi AccGetTrieFn
  result = acc.methods.getTrieFn()
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc getTrie*(mpt: CoreDxMptRef): CoreDbTrieRef =
  ## Variant of `getTrie()`
  mpt.setTrackNewApi MptGetTrieFn
  result = mpt.methods.getTrieFn()
  mpt.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc getTrie*(phk: CoreDxPhkRef): CoreDbTrieRef =
  ## Variant of `getTrie()`
  phk.setTrackNewApi PhkGetTrieFn
  result = phk.methods.getTrieFn()
  phk.ifTrackNewApi: debug newApiTxt, api, elapsed, result


proc persistent*(acc: CoreDxAccRef): CoreDbRc[void] =
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
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc persistent*(mpt: CoreDxMptRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `persistent()`
  mpt.setTrackNewApi MptPersistentFn
  result = mpt.methods.persistentFn()
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, result

proc persistent*(phk: CoreDxPhkRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `persistent()`
  phk.setTrackNewApi PhkPersistentFn
  result = phk.methods.persistentFn()
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, result


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
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc forget*(mpt: CoreDxMptRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `forget()`
  mpt.setTrackNewApi MptForgetFn
  result = mpt.methods.forgetFn()
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, result

proc forget*(phk: CoreDxPhkRef): CoreDbRc[void] {.discardable.} =
  ## Variant of `forget()`
  phk.setTrackNewApi PhkForgetFn
  result = phk.methods.forgetFn()
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, result

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `trie`. The function always returns a
  ## non-empty `Blob` or an error code.
  ##
  mpt.setTrackNewApi MptFetchFn
  result = mpt.methods.fetchFn key
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result

proc fetch*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetch()"
  phk.setTrackNewApi PhkFetchFn
  result = phk.methods.fetchFn key
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result


proc fetchOrEmpty*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## This function returns an empty `Blob` if the argument `key` is not found
  ## on the database.
  ##
  mpt.setTrackNewApi MptFetchOrEmptyFn
  result = mpt.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result

proc fetchOrEmpty*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[Blob] =
  ## Variant of `fetchOrEmpty()`
  phk.setTrackNewApi PhkFetchOrEmptyFn
  result = phk.methods.fetchFn key
  if result.isErr and result.error.error == MptNotFound:
    result = CoreDbRc[Blob].ok(EmptyBlob)
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result


proc delete*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[void] =
  mpt.setTrackNewApi MptDeleteFn
  result = mpt.methods.deleteFn key
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result

proc delete*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[void] =
  phk.setTrackNewApi PhkDeleteFn
  result = phk.methods.deleteFn key
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result


proc merge*(
    mpt: CoreDxMptRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  mpt.setTrackNewApi MptMergeFn
  result = mpt.methods.mergeFn(key, val)
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, val=val.toLenStr, result

proc merge*(
    phk: CoreDxPhkRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  phk.setTrackNewApi PhkMergeFn
  result = phk.methods.mergeFn(key, val)
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, val=val.toLenStr, result


proc hasPath*(mpt: CoreDxMptRef; key: openArray[byte]): CoreDbRc[bool] =
  ## This function would be named `contains()` if it returned `bool` rather
  ## than a `Result[]`.
  ##
  mpt.setTrackNewApi MptHasPathFn
  result = mpt.methods.hasPathFn key
  mpt.ifTrackNewApi:
    let trie = mpt.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result

proc hasPath*(phk: CoreDxPhkRef; key: openArray[byte]): CoreDbRc[bool] =
  ## Variant of `hasPath()`
  phk.setTrackNewApi PhkHasPathFn
  result = phk.methods.hasPathFn key
  phk.ifTrackNewApi:
    let trie = phk.methods.getTrieFn()
    debug newApiTxt, api, elapsed, trie, key=key.toStr, result

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `acc`.
  ##
  acc.setTrackNewApi AccFetchFn
  result = acc.methods.fetchFn address
  acc.ifTrackNewApi:
    let stoTrie = if result.isErr: "n/a" else: result.value.stoTrie.prettyText()
    debug newApiTxt, api, elapsed, address, stoTrie, result

proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  acc.setTrackNewApi AccDeleteFn
  result = acc.methods.deleteFn address
  acc.ifTrackNewApi: debug newApiTxt, api, elapsed, address, result

proc stoFlush*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  ## Recursively delete all data elements from the storage trie associated to
  ## the account identified by the argument `address`. After successful run,
  ## the storage trie will be empty.
  ##
  ## caveat:
  ##   This function has currently no effect on the legacy backend so it must
  ##   not be relied upon in general. On the legacy backend, storage tries
  ##   might be shared by several accounts whereas they are unique on the
  ##   `Aristo` backend.
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

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  ##
  db.setTrackNewApi BaseNewTxFn
  result = db.methods.beginFn()
  db.ifTrackNewApi:
    debug newApiTxt, api, elapsed, newLevel=db.methods.levelFn(), result

proc level*(tx: CoreDxTxRef): int =
  ## Print positive argument `tx` transaction level
  ##
  tx.setTrackNewApi TxLevelFn
  result = tx.methods.levelFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc commit*(tx: CoreDxTxRef, applyDeletes = true): CoreDbRc[void] =
  tx.setTrackNewApi TxCommitFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.commitFn applyDeletes
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel, result

proc rollback*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxRollbackFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.rollbackFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel, result

proc dispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.disposeFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel, result

proc safeDispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.setTrackNewApi TxSaveDisposeFn:
    let prvLevel {.used.} = tx.methods.levelFn()
  result = tx.methods.safeDisposeFn()
  tx.ifTrackNewApi: debug newApiTxt, api, elapsed, prvLevel, result

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
  cp.setTrackNewApi CptFlagsFn
  result = cp.methods.getFlagsFn()
  cp.ifTrackNewApi: debug newApiTxt, api, elapsed, result

proc forget*(cp: CoreDxCaptRef): CoreDbRc[void] =
  ## Explicitely stop recording the current tracer instance. If this call was
  ## successful, the the database argument `db` used when starting the trace
  ## with `newCapture()` will be fully operational, again. This will also
  ## implicitely take place when the`NIM` garbage collector recycles an
  ## abondoned capture descriptor.
  ##
  cp.setTrackNewApi CptForgetFn
  result = cp.methods.forgetFn()
  cp.ifTrackNewApi: debug newApiTxt, api, elapsed, result

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
    dsc.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  # ----------------

  proc kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.setTrackLegaApi LegaNewKvtFn
    result = db.newKvt().CoreDbKvtRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed, result

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.setTrackLegaApi LegaKvtGetFn
    result = kvt.distinctBase.getOrEmpty(key).expect $api
    kvt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr, result

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.setTrackLegaApi LegaKvtDelFn
    kvt.distinctBase.del(key).expect $api
    kvt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr

  proc put*(kvt: CoreDbKvtRef; key: openArray[byte]; val: openArray[byte]) =
    kvt.setTrackLegaApi LegaKvtPutFn
    kvt.distinctBase.parent.newKvt().put(key, val).expect $api
    kvt.ifTrackLegaApi:
      debug legaApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.setTrackLegaApi LegaKvtContainsFn
    result = kvt.distinctBase.hasKey(key).expect $api
    kvt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr, result

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.setTrackLegaApi LegaToMptFn
    result = phk.distinctBase.toMpt.CoreDbMptRef
    phk.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    db.setTrackLegaApi LegaNewMptFn
    let
      trie = db.methods.getTrieFn(GenericTrie, root, none(EthAddress)).valueOr:
        raiseAssert error.prettyText() & ": " & $api
      mpt = db.newMpt(trie, prune).valueOr:
        raiseAssert error.prettyText() & ": " & $api
    result = mpt.CoreDbMptRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed, root, prune

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.setTrackLegaApi LegaNewMptFn
    result = db.newMpt(GenericTrie, none(EthAddress), prune).CoreDbMptRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prune

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.setTrackLegaApi LegaToPhkFn
    result = mpt.distinctBase.toPhk.CoreDbPhkRef
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    db.setTrackLegaApi LegaNewPhkFn
    let
      trie = db.methods.getTrieFn(GenericTrie, root, none(EthAddress)).valueOr:
        raiseAssert error.prettyText() & ": " & $api
      phk = db.newMpt(trie, prune).valueOr:
        raiseAssert error.prettyText() & ": " & $api
    result = phk.toCoreDxPhkRef.CoreDbPhkRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed, root, prune

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.setTrackLegaApi LegaNewPhkFn
    result = db.newMpt(
      GenericTrie, none(EthAddress), prune).toCoreDxPhkRef.CoreDbPhkRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prune

  # ----------------

  proc isPruning*(trie: CoreDbTrieRefs): bool =
    trie.setTrackLegaApi LegaIsPruningFn
    result = trie.distinctBase.isPruning()
    trie.ifTrackLegaApi: debug legaApiTxt, api, elapsed, result


  proc get*(mpt: CoreDbMptRef; key: openArray[byte]): Blob =
    mpt.setTrackLegaApi LegaMptGetFn
    result = mpt.distinctBase.fetchOrEmpty(key).expect $api
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr, result

  proc get*(phk: CoreDbPhkRef; key: openArray[byte]): Blob =
    phk.setTrackLegaApi LegaPhkGetFn
    result = phk.distinctBase.fetchOrEmpty(key).expect $api
    phk.ifTrackLegaApi:
      debug legaApiTxt, api, elapsed, key=key.toStr, result


  proc del*(mpt: CoreDbMptRef; key: openArray[byte]) =
    mpt.setTrackLegaApi LegaMptDelFn
    mpt.distinctBase.delete(key).expect $api
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr

  proc del*(phk: CoreDbPhkRef; key: openArray[byte]) =
    phk.setTrackLegaApi LegaPhkDelFn
    phk.distinctBase.delete(key).expect $api
    phk.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr


  proc put*(mpt: CoreDbMptRef; key: openArray[byte]; val: openArray[byte]) =
    mpt.setTrackLegaApi LegaMptPutFn
    mpt.distinctBase.merge(key, val).expect $api
    mpt.ifTrackLegaApi:
      debug legaApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr

  proc put*(phk: CoreDbPhkRef; key: openArray[byte]; val: openArray[byte]) =
    phk.setTrackLegaApi LegaPhkPutFn
    phk.distinctBase.merge(key, val).expect $api
    phk.ifTrackLegaApi:
      debug legaApiTxt, api, elapsed, key=key.toStr, val=val.toLenStr


  proc contains*(mpt: CoreDbMptRef; key: openArray[byte]): bool =
    mpt.setTrackLegaApi LegaMptContainsFn
    result = mpt.distinctBase.hasPath(key).expect $api
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr, result

  proc contains*(phk: CoreDbPhkRef; key: openArray[byte]): bool =
    phk.setTrackLegaApi LegaPhkContainsFn
    result = phk.distinctBase.hasPath(key).expect $api
    phk.ifTrackLegaApi: debug legaApiTxt, api, elapsed, key=key.toStr, result


  proc rootHash*(mpt: CoreDbMptRef): Hash256 =
    mpt.setTrackLegaApi LegaMptRootHashFn
    result = mpt.distinctBase.methods.getTrieFn().rootHash.valueOr:
      raiseAssert error.prettyText() & ": " & $api
    mpt.ifTrackLegaApi: debug legaApiTxt, api, elapsed, result

  proc rootHash*(phk: CoreDbPhkRef): Hash256 =
    phk.setTrackLegaApi LegaPhkRootHashFn
    result = phk.distinctBase.methods.getTrieFn().rootHash.valueOr:
      raiseAssert error.prettyText() & ": " & $api
    phk.ifTrackLegaApi: debug legaApiTxt, api, elapsed, result

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    db.setTrackLegaApi LegaGetTxIdFn
    result = db.methods.getIdFn().expect($api).CoreDbTxID
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed

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

    id.distinctBase.methods.roWrapperFn(safeFn).expect $api

    # Delayed exception
    if oops.isSome:
      let
        e = oops.unsafeGet
        msg = "delayed and reraised" &
          ", name=" & $e.name & ", msg=\"" & e.msg & "\""
      raise (ref TxWrapperApiError)(msg: msg)
    id.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
    db.setTrackLegaApi LegaBeginTxFn
    result = (db.distinctBase.methods.beginFn().expect $api).CoreDbTxRef
    db.ifTrackLegaApi:
      debug legaApiTxt, api, elapsed, newLevel=db.methods.levelFn()

  proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
    tx.setTrackLegaApi LegaTxCommitFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.commit(applyDeletes).expect $api
    tx.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prvLevel

  proc rollback*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxCommitFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.rollback().expect $api
    tx.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prvLevel

  proc dispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxDisposeFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.dispose().expect $api
    tx.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prvLevel

  proc safeDispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApi LegaTxSaveDisposeFn:
      let prvLevel {.used.} = tx.distinctBase.methods.levelFn()
    tx.distinctBase.safeDispose().expect $api
    tx.ifTrackLegaApi: debug legaApiTxt, api, elapsed, prvLevel

  # ----------------

  proc capture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbCaptRef =
    db.setTrackLegaApi LegaCaptureFn
    result = db.newCapture(flags).expect($api).CoreDbCaptRef
    db.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc recorder*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApi LegaCptRecorderFn
    result = cp.distinctBase.recorder()
    cp.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc logDb*(cp: CoreDbCaptRef): TableRef[Blob,Blob] =
    cp.setTrackLegaApi LegaCptLogDbFn
    result = cp.distinctBase.logDb()
    cp.ifTrackLegaApi: debug legaApiTxt, api, elapsed

  proc flags*(cp: CoreDbCaptRef): set[CoreDbCaptFlags] =
    cp.setTrackLegaApi LegaCptFlagsFn
    result = cp.distinctBase.flags()
    cp.ifTrackLegaApi: debug legaApiTxt, api, elapsed, result

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
