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
  CoreDbBackendRef,
  CoreDbCaptFlags,
  CoreDbError,
  CoreDbKvtBackendRef,
  CoreDbMptBackendRef,
  CoreDbRef,
  CoreDbType,
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
      ## For re-routing exceptions in iterator closure

    CoreDbKvtRef*  = distinct CoreDxKvtRef ## Let methods defect on error
    CoreDbMptRef*  = distinct CoreDxMptRef ## ...
    CoreDbPhkRef*  = distinct CoreDxPhkRef
    CoreDbTxRef*   = distinct CoreDxTxRef
    CoreDbTxID*    = distinct CoreDxTxID
    CoreDbCaptRef* = distinct CoreDxCaptRef

    CoreDbTrieRef* = CoreDbMptRef | CoreDbPhkRef
      ## Shortcut, *MPT* modules for (legacy API)

    CoreDbChldRef* = CoreDbKvtRef | CoreDbTrieRef | CoreDbTxRef | CoreDbTxID |
                     CoreDbCaptRef
      ## Shortcut, all modules with a `parent` (for legacy API)

type
  CoreDxTrieRef* = CoreDxMptRef | CoreDxPhkRef
    ## Shortcut, *MPT* modules

  CoreDxChldRef* = CoreDxKvtRef | CoreDxTrieRef | CoreDxTxRef | CoreDxTxID |
                   CoreDxCaptRef |
                   CoreDbBackendRef | CoreDbKvtBackendRef | CoreDbMptBackendRef
    ## Shortcut, all modules with a `parent`

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

  result.methods.getFn =
    proc(k: openArray[byte]): CoreDbRc[Blob] =
      mpt.methods.getFn(k.keccakHash.data)

  result.methods.maybeGetFn =
    proc(k: openArray[byte]): CoreDbRc[Blob] =
      mpt.methods.maybeGetFn(k.keccakHash.data)

  result.methods.delFn =
    proc(k: openArray[byte]): CoreDbRc[void] =
      mpt.methods.delFn(k.keccakHash.data)

  result.methods.putFn =
    proc(k:openArray[byte]; v:openArray[byte]): CoreDbRc[void] =
      mpt.methods.putFn(k.keccakHash.data, v)

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
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    db:         CoreDbRef;                # Main descriptor, locally extended
    dbType:     CoreDbType;               # Backend symbol
    dbMethods:  CoreDbMiscFns;            # General methods
    kvtMethods: CoreDbKvtFns;             # Kvt related methods
    newSubMod:  CoreDbConstructorFns;     # Sub-module constructors
     ) =
  ## Base descriptor initaliser
  db.dbType = dbType
  db.methods = dbMethods
  db.new = newSubMod

  db.kvtRef = CoreDxKvtRef(
    parent:  db,
    methods: kvtMethods)

  # Disable interator for non-memory instances
  if dbType in CoreDbPersistentTypes:
    db.kvtRef.methods.pairsIt = iterator(): (Blob, Blob) =
      db.itNotImplemented "pairs/kvt"

  when AutoValidateDescriptors:
    db.validate


proc newCoreDbMptRef*(db: CoreDbRef; methods: CoreDbMptFns): CoreDxMptRef =
  ## Hexary trie constructor helper. Will be needed for the
  ## sub-constructors defined in `CoreDbMptConstructor`.
  result = CoreDxMptRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbTxRef*(db: CoreDbRef; methods: CoreDbTxFns): CoreDxTxRef =
  ## Transaction frame constructor helper. Will be needed for the
  ## sub-constructors defined in `CoreDbTxConstructor`.
  result = CoreDxTxRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbTxID*(db: CoreDbRef; methods: CoreDbTxIdFns): CoreDxTxID =
  ## Transaction ID constructor helper.
  result = CoreDxTxID(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbCaptRef*(db: CoreDbRef; methods: CoreDbCaptFns): CoreDxCaptRef =
  ## Capture constructor helper.
  result = CoreDxCaptRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    db.validate

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc dbType*(db: CoreDbRef): CoreDbType =
  ## Getter
  db.dbType

# On the persistent legacy hexary trie, this function is needed for
# bootstrapping and Genesis setup when the `purge` flag is activated.
proc compensateLegacySetup*(db: CoreDbRef) =
  db.methods.legacySetupFn()

func parent*(cld: CoreDxChldRef): CoreDbRef =
  ## Getter, common method for all sub-modules
  cld.parent

proc backend*(db: CoreDbRef): CoreDbBackendRef =
  ## Getter, retrieves the *raw* backend object for special support.
  result = db.methods.backendFn()
  result.parent = db

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

func toKvt*(db: CoreDbRef): CoreDxKvtRef =
  ## Getter (pseudo constructor)
  db.kvtRef

proc get*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  kvt.methods.getFn key

proc maybeGet*(kvt: CoreDxKvtRef; key: openArray[byte]): CoreDbRc[Blob] =
  kvt.methods.maybeGetFn key

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

proc backend*(kvt: CoreDxKvtRef): CoreDbKvtBackendRef =
  ## Getter, retrieves the *raw* backend object for special support.
  result = kvt.methods.backendFn()
  result.parent = kvt.parent

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc newMpt*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbRc[CoreDxMptRef] =
  ## Constructor
  db.new.mptFn root

proc newMptPrune*(
    db: CoreDbRef;
    root = EMPTY_ROOT_HASH;
    prune = true;
      ): CoreDbRc[CoreDxMptRef] =
  ## Constructor, `HexaryTrie` compliant
  db.new.legacyMptFn(root, prune)

proc toMpt*(phk: CoreDxPhkRef): CoreDxMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## The argment `phk` should not be used, anymore.
  phk.fromMpt

# ------------------------------------------------------------------------------
# Public pre-hashed key hexary trie constructors
# ------------------------------------------------------------------------------

proc newPhk*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbRc[CoreDxPhkRef] =
  ## Constructor
  ok (? db.new.mptFn root).toCoreDxPhkRef

proc newPhkPrune*(
    db: CoreDbRef;
    root = EMPTY_ROOT_HASH;
      prune = true;
        ): CoreDbRc[CoreDxPhkRef] =
  ## Constructor, `SecureHexaryTrie` compliant
  ok (? db.new.legacyMptFn(root, prune)).toCoreDxPhkRef

proc toPhk*(mpt: CoreDxMptRef): CoreDxPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*. The argment `mpt` should
  ## not be used, anymore.
  mpt.toCoreDxPhkRef

# ------------------------------------------------------------------------------
# Public hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc isPruning*(trie: CoreDxTrieRef): bool =
  ## Getter
  trie.methods.isPruningFn()

proc get*(trie: CoreDxTrieRef; key: openArray[byte]): CoreDbRc[Blob] =
  trie.methods.getFn(key)

proc maybeGet*(trie: CoreDxTrieRef; key: openArray[byte]): CoreDbRc[Blob] =
  trie.methods.maybeGetFn key

proc del*(trie: CoreDxTrieRef; key: openArray[byte]): CoreDbRc[void] =
  trie.methods.delFn key

proc put*(
    trie: CoreDxTrieRef;
    key: openArray[byte];
    value: openArray[byte];
      ): CoreDbRc[void] =
  trie.methods.putFn(key, value)

proc contains*(trie: CoreDxTrieRef; key: openArray[byte]): CoreDbRc[bool] =
  trie.methods.containsFn key

proc rootHash*(trie: CoreDxTrieRef): CoreDbRc[Hash256] =
  trie.methods.rootHashFn()

iterator pairs*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Trie traversal, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.pairsIt():
    yield (k,v)

iterator replicate*(mpt: CoreDxMptRef): (Blob, Blob) {.apiRaise.} =
  ## Low level trie dump, only supported for `CoreDxMptRef`
  for k,v in mpt.methods.replicateIt():
    yield (k,v)

proc backend*(trie: CoreDxTrieRef): CoreDbMptBackendRef =
  ## Getter, retrieves the *raw* backend object for special support.
  result = trie.methods.backendFn()
  result.parent = trie.parent

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc toTransactionID*(db: CoreDbRef): CoreDbRc[CoreDxTxID] =
  ## Getter, current transaction state
  db.new.getIdFn()

proc shortTimeReadOnly*(
    id: CoreDxTxID;
    action: proc() {.noRaise.};
      ): CoreDbRc[void] =
  ## Run `action()` in an earlier transaction environment.
  id.methods.roWrapperFn action


proc newTransaction*(db: CoreDbRef): CoreDbRc[CoreDxTxRef] =
  ## Constructor
  db.new.beginFn()

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
  db.new.captureFn flags

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

  func parent*(cld: CoreDbChldRef): CoreDbRef =
    ## Getter, common method for all sub-modules
    cld.distinctBase.parent()

  # ----------------

  func kvt*(db: CoreDbRef): CoreDbKvtRef =
    ## Legacy pseudo constructor, see `toKvt()` for production constructor
    db.toKvt.CoreDbKvtRef

  proc get*(kvt: CoreDbKvtRef; key: openArray[byte]): Blob =
    kvt.distinctBase.get(key).expect "kvt/get()"

  proc maybeGet*(kvt: CoreDbKvtRef; key: openArray[byte]): Option[Blob] =
    let rc = kvt.distinctBase.maybeGet key
    if rc.isOk: some(rc.value)
    else: none(Blob)

  proc del*(kvt: CoreDbKvtRef; key: openArray[byte]): void =
    kvt.distinctBase.del(key).expect "kvt/del()"

  proc put*(db: CoreDbKvtRef; key: openArray[byte]; value: openArray[byte]) =
    db.distinctBase.put(key, value).expect "kvt/put()"

  proc contains*(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
    kvt.distinctBase.contains(key).expect "kvt/contains()"

  iterator pairs*(kvt: CoreDbKvtRef): (Blob, Blob) {.apiRaise.} =
    for k,v in kvt.distinctBase.pairs():
      yield (k,v)

  proc backend*(kvt: CoreDbKvtRef): CoreDbKvtBackendRef =
    kvt.distinctBase.backend

  # ----------------

  proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
    phk.distinctBase.toMpt.CoreDbMptRef

  proc mpt*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbMptRef =
    db.newMpt(root).expect("db/mpt()").CoreDbMptRef

  proc mptPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbMptRef =
    db.newMptPrune(root, prune).expect("db/mptPrune()").CoreDbMptRef

  proc mptPrune*(db: CoreDbRef; prune = true): CoreDbMptRef =
    db.newMptPrune(EMPTY_ROOT_HASH, prune).expect("db/mptPrune()").CoreDbMptRef

  # ----------------

  proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
    mpt.distinctBase.toPhk.CoreDbPhkRef

  proc phkPrune*(db: CoreDbRef; root: Hash256; prune = true): CoreDbPhkRef =
    db.newPhkPrune(root, prune).expect("db/phkPrune()").CoreDbPhkRef

  proc phkPrune*(db: CoreDbRef; prune = true): CoreDbPhkRef =
    db.newPhkPrune(EMPTY_ROOT_HASH, prune).expect("db/phkPrune()").CoreDbPhkRef

  # ----------------

  proc isPruning*(trie: CoreDbTrieRef): bool =
    trie.distinctBase.isPruning()

  proc get*(trie: CoreDbTrieRef; key: openArray[byte]): Blob =
    trie.distinctBase.get(key).expect "trie/get()"

  proc maybeGet*(trie: CoreDbTrieRef; key: openArray[byte]): Option[Blob] =
    let rc = trie.distinctBase.maybeGet key
    if rc.isOk: some(rc.value)
    else: none(Blob)

  proc del*(trie: CoreDbTrieRef; key: openArray[byte]) =
    trie.distinctBase.del(key).expect "trie/del()"

  proc put*(
      trie: CoreDbTrieRef;
      key: openArray[byte];
      value: openArray[byte];
        ) =
    trie.distinctBase.put(key, value).expect "trie/put()"

  proc contains*(trie: CoreDbTrieRef; key: openArray[byte]): bool =
    trie.distinctBase.contains(key).expect "trie/contains()"

  proc rootHash*(trie: CoreDbTrieRef): Hash256 =
    trie.distinctBase.rootHash().expect "trie/rootHash()"

  iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Trie traversal, only supported for `CoreDbMptRef`
    for k,v in mpt.distinctBase.pairs():
      yield (k,v)

  iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.apiRaise.} =
    ## Low level trie dump, only supported for `CoreDbMptRef`
    for k,v in mpt.distinctBase.replicate():
      yield (k,v)

  proc backend*(trie: CoreDbTrieRef): CoreDbMptBackendRef =
    trie.distinctBase.backend

  # ----------------

  proc getTransactionID*(db: CoreDbRef): CoreDbTxID =
    (db.toTransactionID().expect "getTransactionID()").CoreDbTxID

  proc setTransactionID*(id: CoreDbTxID) =
    id.distinctBase.methods.setIdFn().expect "txId/setTransactionID()"

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
