# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ./base/[base_desc, validate]

export
  CoreDbAccount,
  CoreDbApiError,
  CoreDbBackendRef,
  CoreDbCaptFlags,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbAccBackendRef,
  CoreDbKvtBackendRef,
  CoreDbMptBackendRef,
  CoreDbRef,
  CoreDbType,
  CoreDbVidRef,
  CoreDxAccRef,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxID,
  CoreDxTxRef

when defined(release):
  const AutoValidateDescriptors = false
else:
  const AutoValidateDescriptors = true

const
  ProvideCoreDbLegacyAPI = true

  EnableApiTracking = true and false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Tracking is enabled by setting the `trackLegaApi`
    ## and/or the `trackNewApi` flags to `true`.

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   apiRaise, gcsafe, raises: [CoreDbApiError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

when ProvideCoreDbLegacyAPI:
  type
    TxWrapperApiError* = object of CoreDbApiError
      ## For re-routing exception on tx/action template

    CoreDbKvtRef*  = distinct CoreDxKvtRef ## Let methods defect on error
    CoreDbMptRef*  = distinct CoreDxMptRef ## ...
    CoreDbPhkRef*  = distinct CoreDxPhkRef
    CoreDbTxRef*   = distinct CoreDxTxRef
    CoreDbTxID*    = distinct CoreDxTxID
    CoreDbCaptRef* = distinct CoreDxCaptRef

    CoreDbTrieRefs* = CoreDbMptRef | CoreDbPhkRef
      ## Shortcut, *MPT* modules for (legacy API)

    CoreDbChldRefs* = CoreDbKvtRef | CoreDbTrieRefs | CoreDbTxRef | CoreDbTxID |
                      CoreDbCaptRef
      ## Shortcut, all modules with a `parent` entry (for legacy API)

type
  CoreDxTrieRefs = CoreDxMptRef | CoreDxPhkRef | CoreDxAccRef
    ## Shortcut, *MPT* descriptors

  CoreDxTrieRelated = CoreDxTrieRefs | CoreDxTxRef | CoreDxTxID | CoreDxCaptRef
    ## Shortcut, descriptors for sub-modules running on an *MPT*

  CoreDbBackends = CoreDbBackendRef | CoreDbKvtBackendRef |
                   CoreDbMptBackendRef | CoreDbAccBackendRef
    ## Shortcut, all backend descriptors.

  CoreDxChldRefs = CoreDxKvtRef | CoreDxTrieRelated | CoreDbVidRef |
                   CoreDbBackends | CoreDbErrorRef
    ## Shortcut, all descriptors with a `parent` entry.

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb " & info

template itNotImplemented(db: CoreDbRef, name: string) =
  warn logTxt "iterator not implemented", dbType=db.dbType, meth=name

# ---------

when EnableApiTracking:
  import std/[sequtils, strutils], stew/byteutils

  template newApiTxt(info: static[string]): static[string] =
    logTxt "new API " & info

  template legaApiTxt(info: static[string]): static[string] =
    logTxt "legacy API " & info

  func getParent(w: CoreDxChldRefs): auto =
    ## Avoida inifinite call to `parent()` in `ifTrack*Api()` tmplates
    w.parent

  template setTrackLegaApiOnly(w: CoreDbChldRefs|CoreDbRef) =
    when typeof(w) is CoreDbRef:
      let db = w
    else:
      let db = w.distinctBase.getParent
    let save = db.trackNewApi
    # Prevent from cascaded logging
    db.trackNewApi = false
    defer: db.trackNewApi = save

  template ifTrackLegaApi(w: CoreDbChldRefs|CoreDbRef; code: untyped) =
    block:
      when typeof(w) is CoreDbRef:
        let db = w
      else:
        let db = w.distinctBase.getParent
      if db.trackLegaApi:
        code

  template ifTrackNewApi(w: CoreDxChldRefs|CoreDbRef; code: untyped) =
    block:
      when typeof(w) is CoreDbRef:
        let db = w
      else:
        if w.isNil: break
        let db = w.getParent
      if db.trackNewApi:
        code

  proc oaToStr(w: openArray[byte]): string =
    w.toHex.toLowerAscii

  proc toStr(w: Hash256): string =
    if w == EMPTY_ROOT_HASH: "EMPTY_ROOT_HASH" else: w.data.oaToStr

  proc toStr(p: CoreDbVidRef): string =
    if p.isNil: "vidRef(nil)" else: "vidRef"

  proc toStr(w: Blob): string =
    if 0 < w.len and w.len < 5: "<" & w.oaToStr & ">"
    else: "Blob[" & $w.len & "]"

  proc toStr(w: openArray[byte]): string =
    w.oaToStr

  proc toStr(w: set[CoreDbCaptFlags]): string =
    "Flags[" & $w.len & "]"

  proc toStr(rc: CoreDbRc[bool]): string =
    if rc.isOk: "ok(" & $rc.value & ")" else: "err(..)"

  proc toStr(rc: CoreDbRc[void]): string =
    if rc.isOk: "ok()" else:"err()"

  proc toStr(rc: CoreDbRc[Blob]): string =
    if rc.isOk: "ok(Blob[" & $rc.value.len & "])" else: "err(..)"

  proc toStr(rc: Result[Hash256,void]): string =
    if rc.isOk: "ok(" & rc.value.toStr & ")" else: "err()"

  proc toStr(rc: Result[Account,void]): string =
    if rc.isOk: "ok(Account)" else: "err()"

  proc toStr[T](rc: CoreDbRc[T]; ifOk: static[string]): string =
    if rc.isOk: "ok(" & ifOk & ")" else: "err(..)"

  proc toStr(rc: CoreDbRc[CoreDbRef]): string = rc.toStr "dbRef"
  proc toStr(rc: CoreDbRc[CoreDbVidRef]): string = rc.toStr "vidRef"
  proc toStr(rc: CoreDbRc[CoreDbAccount]): string = rc.toStr "accRef"
  proc toStr(rc: CoreDbRc[CoreDxTxID]): string = rc.toStr "txId"
  proc toStr(rc: CoreDbRc[CoreDxTxRef]): string = rc.toStr "txRef"
  proc toStr(rc: CoreDbRc[CoreDxCaptRef]): string = rc.toStr "captRef"

else:
  template setTrackLegaApiOnly(w: CoreDbChldRefs|CoreDbRef) = discard
  template ifTrackLegaApi(w: CoreDbChldRefs|CoreDbRef; code: untyped) = discard
  template ifTrackNewApi(w: CoreDxChldRefs|CoreDbRef; code: untyped) = discard

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

  result.methods.containsFn =
    proc(k: openArray[byte]): CoreDbRc[bool] =
      mpt.methods.containsFn(k.keccakHash.data)

  result.methods.pairsIt =
    iterator(): (Blob, Blob) {.apiRaise.} =
      mpt.parent.itNotImplemented("phk/pairs()")

  result.methods.replicateIt =
    iterator(): (Blob, Blob) {.apiRaise.} =
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
  db.ifTrackNewApi: info newApiTxt "CoreDbRef.init()", dbType=db.dbType
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


proc bless*[T: CoreDxTrieRelated | CoreDbErrorRef | CoreDbBackends](
    db: CoreDbRef;
    child: T;
      ): auto =
  ## Complete sub-module descriptor, fill in `parent`.
  child.parent = db
  when AutoValidateDescriptors:
    child.validate
  child

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc dbType*(db: CoreDbRef): CoreDbType =
  ## Getter
  result = db.dbType
  db.ifTrackNewApi: info newApiTxt "dbType()", result

proc compensateLegacySetup*(db: CoreDbRef) =
  ## On the persistent legacy hexary trie, this function is needed for
  ## bootstrapping and Genesis setup when the `purge` flag is activated.
  ## Otherwise the database backend may defect on an internal inconsistency.
  db.methods.legacySetupFn()
  db.ifTrackNewApi: info newApiTxt "compensateLegacySetup()"

proc parent*(cld: CoreDxChldRefs): CoreDbRef =
  ## Getter, common method for all sub-modules
  result = cld.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxTrieRelated | CoreDbRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  result = dsc.methods.backendFn()
  dsc.ifTrackNewApi: info newApiTxt "backend()"

proc finish*(db: CoreDbRef; flush = false) =
  ## Database destructor. If the argument `flush` is set `false`, the database
  ## is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  db.methods.destroyFn flush
  db.ifTrackNewApi: info newApiTxt "finish()"

proc `$$`*(e: CoreDbErrorRef): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  result = e.parent.methods.errorPrintFn(e)
  e.ifTrackNewApi: info newApiTxt "$$()", result

proc hash*(vid: CoreDbVidRef): Result[Hash256,void] =
  ## Getter (well, sort of), retrieves the hash for a `vid` argument. The
  ## function might fail if there is currently no hash available (e.g. on
  ## `Aristo`.) Note that this is different from succeeding with an
  ## `EMPTY_ROOT_HASH` value.
  ##
  ## The value `EMPTY_ROOT_HASH` is also returned on an empty `vid` argument
  ## `CoreDbVidRef(nil)`, say.
  ##
  result = block:
    if not vid.isNil and vid.ready:
      vid.parent.methods.vidHashFn vid
    else:
      ok EMPTY_ROOT_HASH
  # Note: tracker will be silent if `vid` is NIL
  vid.ifTrackNewApi: info newApiTxt "hash()", result=result.toStr

proc hashOrEmpty*(vid: CoreDbVidRef): Hash256 =
  ## Convenience wrapper, returns `EMPTY_ROOT_HASH` where `hash()` would fail.
  vid.hash.valueOr: EMPTY_ROOT_HASH

proc recast*(account: CoreDbAccount): Result[Account,void] =
  ## Convert the argument `account` to the portable Ethereum representation
  ## of an account. This conversion may fail if the storage root hash (see
  ## `hash()` above) is currently unavailable.
  ##
  ## Note that for the legacy backend, this function always succeeds.
  ##
  let vid = account.storageVid
  result = block:
    let rc = vid.hash
    if rc.isOk:
      ok Account(
        nonce:       account.nonce,
        balance:     account.balance,
        codeHash:    account.codeHash,
        storageRoot: rc.value)
    else:
      err()
  vid.ifTrackNewApi: info newApiTxt "recast()", result=result.toStr

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
  ##     let root = db.getRoot(rootHash).isOkOr:
  ##       # some error handling
  ##       return
  ##     db.newAccMpt root
  ##
  result = db.methods.getRootFn(root, createOk)
  db.ifTrackNewApi:
    info newApiTxt "getRoot()", root=root.toStr, result=result.toStr

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc newKvt*(db: CoreDbRef): CoreDxKvtRef =
  ## Getter (pseudo constructor)
  result = db.methods.newKvtFn()
  db.ifTrackNewApi: info newApiTxt "newKvt()"

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  result = kvt.methods.getFn key
  kvt.ifTrackNewApi:
    info newApiTxt "kvt/get()", key=key.toStr, result=result.toStr

proc del*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[void] =
  result = kvt.methods.delFn key
  kvt.ifTrackNewApi:
    info newApiTxt "kvt/del()", key=key.toStr, result=result.toStr

proc put*(
    kvt: CoreDxKvtRef;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  result = kvt.methods.putFn(key, val)
  kvt.ifTrackNewApi: info newApiTxt "kvt/put()",
    key=key.toStr, val=val.toSeq.toStr, result=result.toStr

proc contains*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  result = kvt.methods.containsFn key
  kvt.ifTrackNewApi:
    info newApiTxt "kvt/contains()", key=key.toStr, result=result.toStr

iterator pairs*(kvt: CoreDxKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  for k,v in kvt.methods.pairsIt():
    yield (k,v)
  kvt.ifTrackNewApi: info newApiTxt "kvt/pairs()"

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc newMpt*(db: CoreDbRef; root: CoreDbVidRef; prune = true): CoreDxMptRef =
  ## Constructor, will defect on failure (note that the legacy backend
  ## always succeeds)
  result = db.methods.newMptFn(root, prune).valueOr: raiseAssert $$error
  db.ifTrackNewApi: info newApiTxt "newMpt", root=root.toStr, prune

proc newAccMpt*(db: CoreDbRef; root: CoreDbVidRef; prune = true): CoreDxAccRef =
  ## Similar to `newMpt()` for handling accounts. Although this sub-trie can
  ## be emulated by means of `newMpt(..).toPhk()`, it is recommended using
  ## this constructor which implies its own subset of methods to handle that
  ## trie.
  result = db.methods.newAccFn(root, prune).valueOr: raiseAssert $$error
  db.ifTrackNewApi: info newApiTxt "newAccMpt", root=root.toStr, prune

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAccMpt()`.
  result = phk.fromMpt
  phk.ifTrackNewApi: info newApiTxt "phk/toMpt()"

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAaccMpt()`.
  result = mpt.toCoreDxPhkRef
  mpt.ifTrackNewApi: info newApiTxt "mpt/toPhk()"

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc isPruning*(dsc: CoreDxTrieRefs | CoreDxAccRef): bool =
  ## Getter
  result = dsc.methods.isPruningFn()
  dsc.ifTrackNewApi: info newApiTxt "isPruning()", result

proc rootVid*(dsc: CoreDxTrieRefs | CoreDxAccRef): CoreDbVidRef =
  ## Getter, result is not `nil`
  result = dsc.methods.rootVidFn()
  dsc.ifTrackNewApi: info newApiTxt "rootVid()", result=result.toStr

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `trie`
  result = trie.methods.fetchFn(key)
  trie.ifTrackNewApi:
    info newApiTxt "trie/fetch()", key=key.toStr, result=result.toStr

proc delete*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[void] =
  result = trie.methods.deleteFn key
  trie.ifTrackNewApi:
    info newApiTxt "trie/delete()", key=key.toStr, result=result.toStr

proc merge*(
    trie: CoreDxTrieRefs;
    key: openArray[byte];
    val: openArray[byte];
      ): CoreDbRc[void] =
  when trie is CoreDbMptRef:
    const info = "mpt/merge()"
  else:
    const info = "phk/merge()"
  result = trie.methods.mergeFn(key, val)
  trie.ifTrackNewApi: info newApiTxt info,
    key=key.toStr, val=val.toSeq.toStr, result=result.toStr

proc contains*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[bool] =
  result = trie.methods.containsFn key
  trie.ifTrackNewApi:
    info newApiTxt "trie/contains()", key=key.toStr, result=result.toStr

iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Trie traversal, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.pairsIt():
    yield (k,v)
  mpt.ifTrackNewApi: info newApiTxt "mpt/pairs()"

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.replicateIt():
    yield (k,v)
  mpt.ifTrackNewApi: info newApiTxt "mpt/replicate()"

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `trie`
  result = acc.methods.fetchFn address
  acc.ifTrackNewApi:
    info newApiTxt "acc/fetch()", address=address.toStr, result=result.toStr

proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  result = acc.methods.deleteFn address
  acc.ifTrackNewApi:
    info newApiTxt "acc/delete()", address=address.toStr, result=result.toStr

proc merge*(
    acc: CoreDxAccRef;
    address: EthAddress;
    account: CoreDbAccount;
      ): CoreDbRc[void] =
  result = acc.methods.mergeFn(address, account)
  acc.ifTrackNewApi:
    info newApiTxt "acc/merge()", address=address.toStr, result=result.toStr

proc contains*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[bool] =
  result = acc.methods.containsFn address
  acc.ifTrackNewApi:
    info newApiTxt "acc/contains()", address=address.toStr, result=result.toStr

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc toTransactionID*(db: CoreDbRef): CoreDbRc[CoreDxTxID] =
  ## Getter, current transaction state
  result = db.methods.getIdFn()
  db.ifTrackNewApi: info newApiTxt "toTransactionID()", result=result.toStr

proc shortTimeReadOnly*(
    id: CoreDxTxID;
    action: proc() {.noRaise.};
      ): CoreDbRc[void] =
  ## Run `action()` in an earlier transaction environment.
  result = id.methods.roWrapperFn action
  id.ifTrackNewApi: info newApiTxt "shortTimeReadOnly()", result=result.toStr

proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  result = db.methods.beginFn()
  db.ifTrackNewApi: info newApiTxt "newTransaction()", result=result.toStr

proc commit*(tx: CoreDxTxRef, applyDeletes = true): CoreDbRc[void] =
  result = tx.methods.commitFn applyDeletes
  tx.ifTrackNewApi: info newApiTxt "tx/commit()", result=result.toStr

proc rollback*(tx: CoreDxTxRef): CoreDbRc[void] =
  result = tx.methods.rollbackFn()
  tx.ifTrackNewApi: info newApiTxt "tx/rollback()", result=result.toStr

proc dispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  result = tx.methods.disposeFn()
  tx.ifTrackNewApi: info newApiTxt "tx/dispose()", result=result.toStr

proc safeDispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  result = tx.methods.safeDisposeFn()
  tx.ifTrackNewApi: info newApiTxt "tx/safeDispose()", result=result.toStr

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc newCapture*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbRc[CoreDxCaptRef] =
  ## Constructor
  result = db.methods.captureFn flags
  db.ifTrackNewApi: info newApiTxt "db/capture()", result=result.toStr

proc recorder*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  ## Getter
  result = cp.methods.recorderFn()
  cp.ifTrackNewApi: info newApiTxt "capt/recorder()", result=result.toStr

proc logDb*(cp: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  result = cp.methods.logDbFn()
  cp.ifTrackNewApi: info newApiTxt "capt/logDb()", result=result.toStr

proc flags*(cp: CoreDxCaptRef): set[CoreDbCaptFlags] =
  ## Getter
  result = cp.methods.getFlagsFn()
  cp.ifTrackNewApi: info newApiTxt "capt/flags()", result=result.toStr

# ------------------------------------------------------------------------------
# Public methods, legacy API
# ------------------------------------------------------------------------------

when ProvideCoreDbLegacyAPI:

  proc parent*(cld: CoreDbChldRefs): CoreDbRef =
    ## Getter, common method for all sub-modules
    result = cld.distinctBase.parent

  proc backend*(dsc: CoreDbChldRefs): auto =
    dsc.setTrackLegaApiOnly
    result = dsc.distinctBase.backend
    dsc.ifTrackLegaApi: info legaApiTxt "parent()"

  # ----------------

  proc kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.setTrackLegaApiOnly
    result = db.newKvt().CoreDbKvtRef
    db.ifTrackLegaApi: info legaApiTxt "kvt()"

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.setTrackLegaApiOnly
    const info = "kvt/get()"
    result = kvt.distinctBase.get(key).expect info
    kvt.ifTrackLegaApi:
      info legaApiTxt info, key=key.toStr, result=result.toStr

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.setTrackLegaApiOnly
    const info = "kvt/del()"
    kvt.distinctBase.del(key).expect info
    kvt.ifTrackLegaApi: info legaApiTxt info, key=key.toStr

  proc put*(kvt: CoreDbKvtRef; key: openArray[byte]; val: openArray[byte]) =
    kvt.setTrackLegaApiOnly
    const info = "kvt/put()"
    kvt.distinctBase.put(key, val).expect info
    kvt.ifTrackLegaApi:
      info legaApiTxt info, key=key.toStr, val=val.toSeq.toStr

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.setTrackLegaApiOnly
    const info = "kvt/contains()"
    result = kvt.distinctBase.contains(key).expect info
    kvt.ifTrackLegaApi: info legaApiTxt info, key=key.toStr, result

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    kvt.setTrackLegaApiOnly
    for k,v in kvt.distinctBase.pairs():
      yield (k,v)
    kvt.ifTrackLegaApi: info legaApiTxt "kvt/pairs()"

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.setTrackLegaApiOnly
    result = phk.distinctBase.toMpt.CoreDbMptRef
    phk.ifTrackLegaApi: info legaApiTxt "phk/toMpt()"

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    db.setTrackLegaApiOnly
    const info = "mptPrune()"
    let vid = db.getRoot(root, createOk=true).expect info
    result = db.newMpt(vid, prune).CoreDbMptRef
    db.ifTrackLegaApi: info legaApiTxt info, root=root.toStr, prune

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.newMpt(CoreDbVidRef(nil), prune).CoreDbMptRef

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.setTrackLegaApiOnly
    result = mpt.distinctBase.toPhk.CoreDbPhkRef
    mpt.ifTrackLegaApi: info legaApiTxt "mpt/toMpt()"

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    db.setTrackLegaApiOnly
    const info = "phkPrune()"
    let vid = db.getRoot(root, createOk=true).expect info
    result = db.newMpt(vid, prune).toCoreDxPhkRef.CoreDbPhkRef
    db.ifTrackLegaApi: info legaApiTxt info, root=root.toStr, prune

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.newMpt(CoreDbVidRef(nil), prune).toCoreDxPhkRef.CoreDbPhkRef

  # ----------------

  proc isPruning*(trie: CoreDbTrieRefs): bool =
    trie.setTrackLegaApiOnly
    result = trie.distinctBase.isPruning()
    trie.ifTrackLegaApi: info legaApiTxt "trie/isPruning()", result

  proc get*(trie: CoreDbTrieRefs; key: openArray[byte]): Blob =
    trie.setTrackLegaApiOnly
    const info = "trie/get()"
    result = trie.distinctBase.fetch(key).expect "trie/get()"
    trie.ifTrackLegaApi:
      info legaApiTxt info, key=key.toStr, result=result.toStr

  proc del*(trie: CoreDbTrieRefs; key: openArray[byte]) =
    trie.setTrackLegaApiOnly
    const info = "trie/del()"
    trie.distinctBase.delete(key).expect info
    trie.ifTrackLegaApi: info legaApiTxt info, key=key.toStr

  proc put*(trie: CoreDbTrieRefs; key: openArray[byte]; val: openArray[byte]) =
    trie.setTrackLegaApiOnly
    when trie is CoreDbMptRef:
      const info = "mpt/put()"
    else:
      const info = "phk/put()"
    trie.distinctBase.merge(key, val).expect info
    trie.ifTrackLegaApi:
      info legaApiTxt info, key=key.toStr, val=val.toSeq.toStr

  proc contains*(trie: CoreDbTrieRefs; key: openArray[byte]): bool =
    trie.setTrackLegaApiOnly
    const info = "trie/contains()"
    result = trie.distinctBase.contains(key).expect info
    trie.ifTrackLegaApi: info legaApiTxt info, key=key.toStr, result

  proc rootHash*(trie: CoreDbTrieRefs): Hash256 =
    trie.setTrackLegaApiOnly
    const info = "trie/rootHash()"
    result = trie.distinctBase.rootVid().hash().expect info
    trie.ifTrackLegaApi: info legaApiTxt info, result=result.toStr

  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Trie traversal, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApiOnly
    for k,v in mpt.distinctBase.pairs():
      yield (k,v)
    mpt.ifTrackLegaApi: info legaApiTxt "mpt/pairs()"

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    mpt.setTrackLegaApiOnly
    for k,v in mpt.distinctBase.replicate():
      yield (k,v)
    mpt.ifTrackLegaApi: info legaApiTxt "mpt/replicate()"

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    db.setTrackLegaApiOnly
    const info = "getTransactionID()"
    result = (db.toTransactionID().expect info).CoreDbTxID
    db.ifTrackLegaApi: info legaApiTxt info

  proc shortTimeReadOnly*(
      id: CoreDbTxID;
      action: proc() {.catchRaise.};
        ) {.catchRaise.} =
    id.setTrackLegaApiOnly
    const info = "txId/shortTimeReadOnly()"
    var oops = none(ref CatchableError)
    proc safeFn() =
      try:
        action()
      except CatchableError as e:
        oops = some(e)
      # Action has finished now

    id.distinctBase.shortTimeReadOnly(safeFn).expect info

    # Delayed exception
    if oops.isSome:
      let
        e = oops.unsafeGet
        msg = "delayed and reraised" &
          ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
      raise (ref TxWrapperApiError)(msg: msg)
    id.ifTrackLegaApi: info legaApiTxt info

  proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
    db.setTrackLegaApiOnly
    const info = "newTransaction()"
    result = (db.distinctBase.newTransaction().expect info).CoreDbTxRef
    db.ifTrackLegaApi: info legaApiTxt info

  proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
    tx.setTrackLegaApiOnly
    const info = "tx/commit()"
    tx.distinctBase.commit(applyDeletes).expect info
    tx.ifTrackLegaApi: info legaApiTxt info

  proc rollback*(tx: CoreDbTxRef) =
    tx.setTrackLegaApiOnly
    const info = "tx/rollback()"
    tx.distinctBase.rollback().expect info
    tx.ifTrackLegaApi: info legaApiTxt info

  proc dispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApiOnly
    const info = "tx/dispose()"
    tx.distinctBase.dispose().expect info
    tx.ifTrackLegaApi: info legaApiTxt info

  proc safeDispose*(tx: CoreDbTxRef) =
    tx.setTrackLegaApiOnly
    const info = "tx/safeDispose()"
    tx.distinctBase.safeDispose().expect info
    tx.ifTrackLegaApi: info legaApiTxt info

  # ----------------

  proc capture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbCaptRef =
    db.setTrackLegaApiOnly
    const info = "db/capture()"
    result = db.newCapture(flags).expect(info).CoreDbCaptRef
    db.ifTrackLegaApi: info legaApiTxt info

  proc recorder*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApiOnly
    const info = "capt/recorder()"
    result = cp.distinctBase.recorder().expect info
    cp.ifTrackLegaApi: info legaApiTxt info

  proc logDb*(cp: CoreDbCaptRef): CoreDbRef =
    cp.setTrackLegaApiOnly
    const info = "capt/logDb()"
    result = cp.distinctBase.logDb().expect info
    cp.ifTrackLegaApi: info legaApiTxt info

  proc flags*(cp: CoreDbCaptRef): set[CoreDbCaptFlags] =
    cp.setTrackLegaApiOnly
    result = cp.distinctBase.flags()
    cp.ifTrackLegaApi: info legaApiTxt "capt/flags()", result=result.toStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
