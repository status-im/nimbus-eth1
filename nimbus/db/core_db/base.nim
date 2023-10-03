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
  std/[options, typetraits],
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

logScope:
  topics = "core_db-base"

when defined(release):
  const AutoValidateDescriptors = false
else:
  const AutoValidateDescriptors = true

const
  ProvideCoreDbLegacyAPI = true

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

  CoreDxChldRefs = CoreDxKvtRef | CoreDxTrieRelated | CoreDbBackends |
                   CoreDbErrorRef
    ## Shortcut, all descriptors with a `parent` entry.

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb " & info

template itNotImplemented(db: CoreDbRef, name: string) =
  warn logTxt "iterator not implemented", dbType=db.dbType, meth=name

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
      mpt.parent.itNotImplemented("pairs/phk")

  result.methods.replicateIt =
    iterator(): (Blob, Blob) {.apiRaise.} =
      mpt.parent.itNotImplemented("replicate/phk")

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
  db.dbType

proc compensateLegacySetup*(db: CoreDbRef) =
  ## On the persistent legacy hexary trie, this function is needed for
  ## bootstrapping and Genesis setup when the `purge` flag is activated.
  ## Otherwise the database backend may defect on an internal inconsistency.
  db.methods.legacySetupFn()

func parent*(cld: CoreDxChldRefs): CoreDbRef =
  ## Getter, common method for all sub-modules
  cld.parent

proc backend*(dsc: CoreDxKvtRef | CoreDxTrieRelated | CoreDbRef): auto =
  ## Getter, retrieves the *raw* backend object for special/localised support.
  dsc.methods.backendFn()

proc finish*(db: CoreDbRef; flush = false) =
  ## Database destructor. If the argument `flush` is set `false`, the database
  ## is left as-is and only the in-memory handlers are cleaned up.
  ##
  ## Otherwise the destructor is allowed to remove the database. This feature
  ## depends on the backend database. Currently, only the `AristoDbRocks` type
  ## backend removes the database on `true`.
  db.methods.destroyFn flush

proc `$$`*(e: CoreDbErrorRef): string =
  ## Pretty print error symbol, note that this directive may have side effects
  ## as it calls a backend function.
  e.parent.methods.errorPrintFn(e)

proc hash*(vid: CoreDbVidRef): Result[Hash256,void] =
  ## Getter (well, sort of), retrieves the hash for a `vid` argument. The
  ## function might fail if there is currently no hash available (e.g. on
  ## `Aristo`.) Note that this is different from succeeding with an
  ## `EMPTY_ROOT_HASH` value.
  ##
  ## The value `EMPTY_ROOT_HASH` is also returned on an empty `vid` argument
  ## `CoreDbVidRef(nil)`, say.
  ##
  if not vid.isNil and vid.ready:
    return vid.parent.methods.vidHashFn vid
  ok EMPTY_ROOT_HASH

proc recast*(account: CoreDbAccount): Result[Account,void] =
  ## Convert the argument `account` to the portable Ethereum representation
  ## of an account. This conversion may fail if the storage root hash (see
  ## `hash()` above) is currently unavailable.
  ##
  ## Note that for the legacy backend, this function always succeeds.
  ##
  ok Account(
    nonce:       account.nonce,
    balance:     account.balance,
    codeHash:    account.codeHash,
    storageRoot: ? account.storageVid.hash)

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
  db.methods.getRootFn(root, createOk)

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc newKvt*(db: CoreDbRef): CoreDxKvtRef =
  ## Getter (pseudo constructor)
  db.methods.newKvtFn()

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  kvt.methods.getFn key

proc del*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[void] =
  kvt.methods.delFn key

proc put*(
    kvt: CoreDxKvtRef;
    key: openArray[byte];
    value: openArray[byte];
      ): CoreDbRc[void] =
  kvt.methods.putFn(key, value)

proc contains*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[bool] =
  kvt.methods.containsFn key

iterator pairs*(kvt: CoreDxKvtRef): (Blob, Blob) {.apiRaise.} =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  for k,v in kvt.methods.pairsIt():
    yield (k,v)

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc newMpt*(db: CoreDbRef; root: CoreDbVidRef; prune = true): CoreDxMptRef =
  ## Constructor, will defect on failure (note that the legacy backend
  ## always succeeds)
  db.methods.newMptFn(root, prune).valueOr: raiseAssert $$error

proc newAccMpt*(db: CoreDbRef; root: CoreDbVidRef; prune = true): CoreDxAccRef =
  ## Similar to `newMpt()` for handling accounts. Although this sub-trie can
  ## be emulated by means of `newMpt(..).toPhk()`, it is recommended using
  ## this constructor which implies its own subset of methods to handle that
  ## trie.
  db.methods.newAccFn(root, prune).valueOr: raiseAssert $$error

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAccMpt()`.
  phk.fromMpt

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*.
  ## Note that this does not apply to an accounts trie that was created by
  ## `newAaccMpt()`.
  mpt.toCoreDxPhkRef

# ------------------------------------------------------------------------------
# Public common methods for all hexary trie databases (`mpt`, `phk`, or `acc`)
# ------------------------------------------------------------------------------

proc isPruning*(dsc: CoreDxTrieRefs | CoreDxAccRef): bool =
  ## Getter
  dsc.methods.isPruningFn()

proc rootVid*(dsc: CoreDxTrieRefs | CoreDxAccRef): CoreDbVidRef =
  ## Getter, result is not `nil`
  dsc.methods.rootVidFn()

# ------------------------------------------------------------------------------
# Public generic hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc fetch*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[Blob] =
  ## Fetch data from the argument `trie`
  trie.methods.fetchFn(key)

proc delete*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[void] =
  trie.methods.deleteFn key

proc merge*(
    trie: CoreDxTrieRefs;
    key: openArray[byte];
    value: openArray[byte];
      ): CoreDbRc[void] =
  trie.methods.mergeFn(key, value)

proc contains*(trie: CoreDxTrieRefs; key: openArray[byte]): CoreDbRc[bool] =
  trie.methods.containsFn key

iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Trie traversal, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.pairsIt():
    yield (k,v)

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.replicateIt():
    yield (k,v)

# ------------------------------------------------------------------------------
# Public trie database methods for accounts
# ------------------------------------------------------------------------------

proc fetch*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[CoreDbAccount] =
  ## Fetch data from the argument `trie`
  acc.methods.fetchFn address

proc delete*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[void] =
  acc.methods.deleteFn address

proc merge*(
    acc: CoreDxAccRef;
    address: EthAddress;
    account: CoreDbAccount;
      ): CoreDbRc[void] =
  acc.methods.mergeFn(address, account)

proc contains*(acc: CoreDxAccRef; address: EthAddress): CoreDbRc[bool] =
  acc.methods.containsFn address

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc toTransactionID*(db: CoreDbRef): CoreDbRc[CoreDxTxID] =
  ## Getter, current transaction state
  db.methods.getIdFn()

proc shortTimeReadOnly*(
    id: CoreDxTxID;
    action: proc() {.noRaise.};
      ): CoreDbRc[void] =
  ## Run `action()` in an earlier transaction environment.
  id.methods.roWrapperFn action


proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  db.methods.beginFn()

proc commit*(tx: CoreDxTxRef, applyDeletes = true): CoreDbRc[void] =
  tx.methods.commitFn applyDeletes

proc rollback*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.methods.rollbackFn()

proc dispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.methods.disposeFn()

proc safeDispose*(tx: CoreDxTxRef): CoreDbRc[void] =
  tx.methods.safeDisposeFn()

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc newCapture*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbRc[CoreDxCaptRef] =
  ## Constructor
  db.methods.captureFn flags

proc recorder*(db: CoreDxCaptRef): CoreDbRc[CoreDbRef] =
  ## Getter
  db.methods.recorderFn()

proc flags*(db: CoreDxCaptRef): set[CoreDbCaptFlags] =
  ## Getter
  db.methods.getFlagsFn()

# ------------------------------------------------------------------------------
# Public methods, legacy API
# ------------------------------------------------------------------------------

when ProvideCoreDbLegacyAPI:

  func parent*(cld: CoreDbChldRefs): CoreDbRef =
    ## Getter, common method for all sub-modules
    cld.distinctBase.parent()

  proc backend*(dsc: CoreDbChldRefs): auto =
    dsc.distinctBase.backend

  # ----------------

  proc kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.newKvt().CoreDbKvtRef

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.distinctBase.get(key).expect "kvt/get()"

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.distinctBase.del(key).expect "kvt/del()"

  proc put*(db: CoreDbKvtRef; key: openArray[byte]; value: openArray[byte]) =
    db.distinctBase.put(key, value).expect "kvt/put()"

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.distinctBase.contains(key).expect "kvt/contains()"

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    for k,v in kvt.distinctBase.pairs():
      yield (k,v)

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.distinctBase.toMpt.CoreDbMptRef

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    let vid = db.getRoot(root, createOk=true).expect "mpt/getRoot()"
    db.newMpt(vid, prune).CoreDbMptRef

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.newMpt(CoreDbVidRef(nil), prune).CoreDbMptRef

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.distinctBase.toPhk.CoreDbPhkRef

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    let vid = db.getRoot(root, createOk=true).expect "phk/getRoot()"
    db.newMpt(vid, prune).toCoreDxPhkRef.CoreDbPhkRef

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.newMpt(CoreDbVidRef(nil), prune).toCoreDxPhkRef.CoreDbPhkRef

  # ----------------

  proc isPruning*(trie: CoreDbTrieRefs): bool =
    trie.distinctBase.isPruning()

  proc get*(trie: CoreDbTrieRefs; key: openArray[byte]): Blob =
    trie.distinctBase.fetch(key).expect "trie/get()"

  proc del*(trie: CoreDbTrieRefs; key: openArray[byte]) =
    trie.distinctBase.delete(key).expect "trie/del()"

  proc put*(trie: CoreDbTrieRefs; key: openArray[byte]; val: openArray[byte]) =
    trie.distinctBase.merge(key, val).expect "trie/put()"

  proc contains*(trie: CoreDbTrieRefs; key: openArray[byte]): bool =
    trie.distinctBase.contains(key).expect "trie/contains()"

  proc rootHash*(trie: CoreDbTrieRefs): Hash256 =
    trie.distinctBase.rootVid().hash().expect "trie/rootHash()"

  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Trie traversal, not supported for `CoreDbPhkRef`
    for k,v in mpt.distinctBase.pairs():
      yield (k,v)

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, not supported for `CoreDbPhkRef`
    for k,v in mpt.distinctBase.replicate():
      yield (k,v)

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    (db.toTransactionID().expect "getTransactionID()").CoreDbTxID

  proc shortTimeReadOnly*(
      id: CoreDbTxID;
      action: proc() {.catchRaise.};
        ) {.catchRaise.} =
    var oops = none(ref CatchableError)
    proc safeFn() =
      try:
        action()
      except CatchableError as e:
        oops = some(e)
      # Action has finished now

    id.distinctBase.shortTimeReadOnly(safeFn).expect "txId/shortTimeReadOnly()"

    # Delayed exception
    if oops.isSome:
      let
        e = oops.unsafeGet
        msg = "delayed and reraised" &
          ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""
      raise (ref TxWrapperApiError)(msg: msg)

  proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
    (db.distinctBase.newTransaction().expect "newTransaction()").CoreDbTxRef

  proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
    tx.distinctBase.commit(applyDeletes).expect "tx/commit()"

  proc rollback*(tx: CoreDbTxRef) =
    tx.distinctBase.rollback().expect "tx/rollback()"

  proc dispose*(tx: CoreDbTxRef) =
    tx.distinctBase.dispose().expect "tx/dispose()"

  proc safeDispose*(tx: CoreDbTxRef) =
    tx.distinctBase.safeDispose().expect "tx/safeDispose()"

  # ----------------

  proc capture*(
      db: CoreDbRef;
      flags: set[CoreDbCaptFlags] = {};
        ): CoreDbCaptRef =
    db.newCapture(flags).expect("db/capture()").CoreDbCaptRef

  proc recorder*(db: CoreDbCaptRef): CoreDbRef =
    db.distinctBase.recorder().expect("db/recorder()")

  proc flags*(db: CoreDbCaptRef): set[CoreDbCaptFlags] =
    db.distinctBase.flags()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
