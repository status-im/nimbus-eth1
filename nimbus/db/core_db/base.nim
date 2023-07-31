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
  std/options,
  chronicles,
  eth/common,
  ../../constants

logScope:
  topics = "core_db-base"

when defined(release):
  const AutoValidateDescriptors = false
else:
  const AutoValidateDescriptors = true

type
  CoreDbCaptFlags* {.pure.} = enum
    PersistPut
    PersistDel

  CoreDbType* = enum
    Ooops
    LegacyDbMemory
    LegacyDbPersistent
    # AristoDbMemory
    # AristoDbPersistent

  # --------------------------------------------------
  # Constructors
  # --------------------------------------------------
  CoreDbNewMptFn* = proc(root: Hash256): CoreDbMptRef {.gcsafe, raises: [].}
  CoreDbNewLegacyMptFn* = proc(root: Hash256; prune: bool): CoreDbMptRef
                            {.gcsafe, raises: [].}
  CoreDbNewTxGetIdFn* = proc(): CoreDbTxID {.gcsafe, raises: [].}
  CoreDbNewTxBeginFn* = proc(): CoreDbTxRef {.gcsafe, raises: [].}
  CoreDbNewCaptFn = proc(flags: set[CoreDbCaptFlags] = {}): CoreDbCaptRef
                      {.gcsafe, raises: [].}

  CoreDbConstructors* = object
    ## Constructors

    # Hexary trie
    mptFn*:       CoreDbNewMptFn
    legacyMptFn*: CoreDbNewLegacyMptFn # Legacy handler, should go away

    # Transactions
    getIdFn*:     CoreDbNewTxGetIdFn
    beginFn*:     CoreDbNewTxBeginFn

    # capture/tracer
    captureFn*:   CoreDbNewCaptFn


  # --------------------------------------------------
  # Sub-descriptor: Misc methods for main descriptor
  # --------------------------------------------------
  CoreDbInitLegaSetupFn* = proc() {.gcsafe, raises: [].}

  CoreDbMiscFns* = object
    legacySetupFn*: CoreDbInitLegaSetupFn

  # --------------------------------------------------
  # Sub-descriptor: KVT methods
  # --------------------------------------------------
  CoreDbKvtGetFn* = proc(k: openArray[byte]): Blob {.gcsafe, raises: [].}
  CoreDbKvtMaybeGetFn* = proc(key: openArray[byte]): Option[Blob]
                           {.gcsafe, raises: [].}
  CoreDbKvtDelFn* = proc(k: openArray[byte]) {.gcsafe, raises: [].}
  CoreDbKvtPutFn* = proc(k: openArray[byte]; v: openArray[byte])
                      {.gcsafe, raises: [].}
  CoreDbKvtContainsFn* = proc(k: openArray[byte]): bool {.gcsafe, raises: [].}
  CoreDbKvtPairsIt* = iterator(): (Blob,Blob) {.gcsafe, raises: [].}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    getFn*:      CoreDbKvtGetFn
    maybeGetFn*: CoreDbKvtMaybeGetFn
    delFn*:      CoreDbKvtDelFn
    putFn*:      CoreDbKvtPutFn
    containsFn*: CoreDbKvtContainsFn
    pairsIt*:    CoreDbKvtPairsIt


  # --------------------------------------------------
  # Sub-descriptor: Mpt/hexary trie methods
  # --------------------------------------------------
  CoreDbMptGetFn* = proc(k: openArray[byte]): Blob
                      {.gcsafe, raises: [RlpError].}
  CoreDbMptMaybeGetFn* = proc(k: openArray[byte]): Option[Blob]
                           {.gcsafe, raises: [RlpError].}
  CoreDbMptDelFn* = proc(k: openArray[byte]) {.gcsafe, raises: [RlpError].}
  CoreDbMptPutFn* = proc(k: openArray[byte]; v: openArray[byte])
                      {.gcsafe, raises: [RlpError].}
  CoreDbMptContainsFn* = proc(k: openArray[byte]): bool
                           {.gcsafe, raises: [RlpError].}
  CoreDbMptRootHashFn* = proc(): Hash256 {.gcsafe, raises: [].}
  CoreDbMptIsPruningFn* = proc(): bool {.gcsafe, raises: [].}
  CoreDbMptPairsIt* = iterator(): (Blob,Blob) {.gcsafe, raises: [RlpError].}
  CoreDbMptReplicateIt* = iterator(): (Blob,Blob) {.gcsafe, raises: [RlpError].}

  CoreDbMptFns* = object
    ## Methods for trie objects `CoreDbMptRef`
    getFn*:       CoreDbMptGetFn
    maybeGetFn*:  CoreDbMptMaybeGetFn
    delFn*:       CoreDbMptDelFn
    putFn*:       CoreDbMptPutFn
    containsFn*:  CoreDbMptContainsFn
    rootHashFn*:  CoreDbMptRootHashFn
    pairsIt*:     CoreDbMptPairsIt
    replicateIt*: CoreDbMptReplicateIt
    isPruningFn*: CoreDbMptIsPruningFn # Legacy handler, should go away


  # --------------------------------------------------
  # Sub-descriptor: Transaction frame management
  # --------------------------------------------------
  CoreDbTxCommitFn* = proc(applyDeletes: bool) {.gcsafe, raises: [].}
  CoreDbTxRollbackFn* = proc() {.gcsafe, raises: [].}
  CoreDbTxDisposeFn* = proc() {.gcsafe, raises: [].}
  CoreDbTxSafeDisposeFn* = proc() {.gcsafe, raises: [].}

  CoreDbTxFns* = object
    commitFn*:      CoreDbTxCommitFn
    rollbackFn*:    CoreDbTxRollbackFn
    disposeFn*:     CoreDbTxDisposeFn
    safeDisposeFn*: CoreDbTxSafeDisposeFn

  # --------------------------------------------------
  # Sub-descriptor: Transaction ID management
  # --------------------------------------------------
  CoreDbTxIdSetIdFn* = proc() {.gcsafe, raises: [].}
  CoreDbTxIdActionFn* = proc() {.gcsafe, raises: [CatchableError].}
  CoreDbTxIdRoWrapperFn* = proc(action: CoreDbTxIdActionFn)
                             {.gcsafe, raises: [CatchableError].}
  CoreDbTxIdFns* = object
    setIdFn*:     CoreDbTxIdSetIdFn
    roWrapperFn*: CoreDbTxIdRoWrapperFn


  # --------------------------------------------------
  # Sub-descriptor: capture recorder methods
  # --------------------------------------------------
  CoreDbCaptRecorderFn* = proc(): CoreDbRef {.gcsafe, raises: [].}
  CoreDbCaptFlagsFn* = proc(): set[CoreDbCaptFlags] {.gcsafe, raises: [].}

  CoreDbCaptFns* = object
    recorderFn*: CoreDbCaptRecorderFn
    getFlagsFn*: CoreDbCaptFlagsFn

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------

  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    kvt: CoreDbKvtObj
    new: CoreDbConstructors
    methods: CoreDbMiscFns

  CoreDbKvtObj* = object
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    dbType: CoreDbType
    methods: CoreDbKvtFns

  CoreDbMptRef* = ref object
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent: CoreDbRef
    methods: CoreDbMptFns

  CoreDbPhkRef* = ref object
    ## Similar to `CoreDbMptRef` but with pre-hashed keys. That is, any
    ## argument key for `put()`, `get()` etc. will be hashed first before
    ## being applied.
    parent: CoreDbMptRef
    methods: CoreDbMptFns

  CoreDbTxRef* = ref object
    ## Transaction descriptor derived from `CoreDbRef`
    parent: CoreDbRef
    methods: CoreDbTxFns

  CoreDbTxID* = ref object
    ## Transaction ID descriptor derived from `CoreDbRef`
    parent: CoreDbRef
    methods: CoreDbTxIdFns

  CoreDbCaptRef* = ref object
    ## Db transaction tracer derived from `CoreDbRef`
    parent: CoreDbRef
    methods: CoreDbCaptFns

  MethodsDesc =
    CoreDbKvtObj |
    CoreDbMptRef | CoreDbPhkRef |
    CoreDbTxRef  | CoreDbTxID   |
    CoreDbCaptRef

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb " & info

template itNotImplemented(db: CoreDbRef, name: string) =
  warn logTxt "iterator not implemented", dbType=db.kvt.dbType, meth=name

# ---------

proc validateMethodsDesc(db: CoreDbRef) =
  doAssert not db.methods.legacySetupFn.isNil

proc validateMethodsDesc(kvt: CoreDbKvtObj) =
  doAssert kvt.dbType != CoreDbType(0)
  doAssert not kvt.methods.getFn.isNil
  doAssert not kvt.methods.maybeGetFn.isNil
  doAssert not kvt.methods.delFn.isNil
  doAssert not kvt.methods.putFn.isNil
  doAssert not kvt.methods.containsFn.isNil
  doAssert not kvt.methods.pairsIt.isNil

proc validateMethodsDesc(trie: CoreDbMptRef|CoreDbPhkRef) =
  doAssert not trie.parent.isNil
  doAssert not trie.methods.getFn.isNil
  doAssert not trie.methods.maybeGetFn.isNil
  doAssert not trie.methods.delFn.isNil
  doAssert not trie.methods.putFn.isNil
  doAssert not trie.methods.containsFn.isNil
  doAssert not trie.methods.rootHashFn.isNil
  doAssert not trie.methods.isPruningFn.isNil
  doAssert not trie.methods.pairsIt.isNil
  doAssert not trie.methods.replicateIt.isNil

proc validateMethodsDesc(cpt: CoreDbCaptRef) =
  doAssert not cpt.parent.isNil
  doAssert not cpt.methods.recorderFn.isNil
  doAssert not cpt.methods.getFlagsFn.isNil

proc validateMethodsDesc(tx: CoreDbTxRef) =
  doAssert not tx.parent.isNil
  doAssert not tx.methods.commitFn.isNil
  doAssert not tx.methods.rollbackFn.isNil
  doAssert not tx.methods.disposeFn.isNil
  doAssert not tx.methods.safeDisposeFn.isNil

proc validateMethodsDesc(id: CoreDbTxID) =
  doAssert not id.parent.isNil
  doAssert not id.methods.setIdFn.isNil
  doAssert not id.methods.roWrapperFn.isNil

proc validateConstructors(new: CoreDbConstructors) =
  doAssert not new.mptFn.isNil
  doAssert not new.legacyMptFn.isNil
  doAssert not new.getIdFn.isNil
  doAssert not new.beginFn.isNil
  doAssert not new.captureFn.isNil

# ---------

proc toCoreDbPhkRef(mpt: CoreDbMptRef): CoreDbPhkRef =
  ## MPT => pre-hashed MPT (aka PHK)
  result = CoreDbPhkRef(
    parent:  mpt,
    methods: CoreDbMptFns(
      getFn: proc(k: openArray[byte]): Blob
          {.gcsafe, raises: [RlpError].} =
        return mpt.methods.getFn(k.keccakHash.data),

      maybeGetFn: proc(k: openArray[byte]): Option[Blob]
          {.gcsafe, raises: [RlpError].} =
        return mpt.methods.maybeGetFn(k.keccakHash.data),

      delFn: proc(k: openArray[byte])
          {.gcsafe, raises: [RlpError].} =
        mpt.methods.delFn(k.keccakHash.data),

      putFn: proc(k:openArray[byte]; v:openArray[byte])
         {.gcsafe, raises: [RlpError].} =
        mpt.methods.putFn(k.keccakHash.data, v),

      containsFn: proc(k: openArray[byte]): bool
          {.gcsafe, raises: [RlpError].} =
        return mpt.methods.containsFn(k.keccakHash.data),

      pairsIt: iterator(): (Blob, Blob) {.gcsafe.} =
        mpt.parent.itNotImplemented("pairs/phk"),

      replicateIt: iterator(): (Blob, Blob) {.gcsafe.} =
        mpt.parent.itNotImplemented("replicate/phk"),

      rootHashFn: mpt.methods.rootHashFn,
      isPruningFn: mpt.methods.isPruningFn))

  when AutoValidateDescriptors:
    result.validateMethodsDesc


proc kvtUpdate(db: CoreDbRef) =
  ## Disable interator for non-memory instances
  case db.kvt.dbType
  of LegacyDbMemory:
    discard
  else:
    db.kvt.methods.pairsIt = iterator(): (Blob, Blob) =
      db.itNotImplemented "pairs/kvt"

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc validate*(desc: MethodsDesc) =
  desc.validateMethodsDesc

proc validate*(db: CoreDbRef) =
  db.validateMethodsDesc
  db.kvt.validateMethodsDesc
  db.new.validateConstructors

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    db:         CoreDbRef;
    dbType:     CoreDbType;
    dbMethods:  CoreDbMiscFns;
    kvtMethods: CoreDbKvtFns;
    new:        CoreDbConstructors
     ) =
  ## Base descriptor initaliser
  db.methods = dbMethods
  db.new = new

  db.kvt.dbType = dbType
  db.kvt.methods = kvtMethods
  db.kvtUpdate()

  when AutoValidateDescriptors:
    db.validate


proc newCoreDbMptRef*(db: CoreDbRef; methods: CoreDbMptFns): CoreDbMptRef =
  ## Hexary trie constructor helper. Will be needed for the
  ## sub-constructors defined in `CoreDbMptConstructor`.
  result = CoreDbMptRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbTxRef*(db: CoreDbRef; methods: CoreDbTxFns): CoreDbTxRef =
  ## Transaction frame constructor helper. Will be needed for the
  ## sub-constructors defined in `CoreDbTxConstructor`.
  result = CoreDbTxRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbTxID*(db: CoreDbRef; methods: CoreDbTxIdFns): CoreDbTxID =
  ## Transaction ID constructor helper.
  result = CoreDbTxID(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    result.validate


proc newCoreDbCaptRef*(db: CoreDbRef; methods: CoreDbCaptFns): CoreDbCaptRef =
  ## Capture constructor helper.
  result = CoreDbCaptRef(
    parent:  db,
    methods: methods)

  when AutoValidateDescriptors:
    db.validate

# ------------------------------------------------------------------------------
# Public main descriptor methods
# ------------------------------------------------------------------------------

proc dbType*(db: CoreDbRef): CoreDbType =
  ## Getter
  db.kvt.dbType

# On the persistent legacy hexary trie, this function is needed for
# bootstrapping and Genesis setup when the `purge` flag is activated.
proc compensateLegacySetup*(db: CoreDbRef) =
  db.methods.legacySetupFn()

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc kvt*(db: CoreDbRef): CoreDbKvtObj =
  ## Getter (pseudo constructor)
  db.kvt

proc dbType*(db: CoreDbKvtObj): CoreDbType =
  ## Getter
  db.dbType

proc get*(db: CoreDbKvtObj; key: openArray[byte]): Blob =
  db.methods.getFn key

proc maybeGet*(db: CoreDbKvtObj; key: openArray[byte]): Option[Blob] =
  db.methods.maybeGetFn key

proc del*(db: CoreDbKvtObj; key: openArray[byte]) =
  db.methods.delFn key

proc put*(db: CoreDbKvtObj; key: openArray[byte]; value: openArray[byte]) =
  db.methods.putFn(key, value)

proc contains*(db: CoreDbKvtObj; key: openArray[byte]): bool =
  db.methods.containsFn key

iterator pairs*(db: CoreDbKvtObj): (Blob, Blob) =
  ## Iterator supported on memory DB (otherwise implementation dependent)
  for k,v in db.methods.pairsIt():
    yield (k,v)

# ------------------------------------------------------------------------------
# Public Merkle Patricia Tree, hexary trie constructors
# ------------------------------------------------------------------------------

proc mpt*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbMptRef =
  ## Constructor
  db.new.mptFn root

proc mptPrune*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbMptRef =
  ## Constructor
  db.new.legacyMptFn(root, true)

proc mptPrune*(db: CoreDbRef; root: Hash256; prune: bool): CoreDbMptRef =
  ## Constructor
  db.new.legacyMptFn(root, prune)

proc mptPrune*(db: CoreDbRef; prune: bool): CoreDbMptRef =
  ## Constructor
  db.new.legacyMptFn(EMPTY_ROOT_HASH, prune)

# ------------------------------------------------------------------------------
# Public pre-hashed key hexary trie constructors
# ------------------------------------------------------------------------------

proc phk*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbPhkRef =
  ## Constructor
  db.new.mptFn(root).toCoreDbPhkRef

proc phkPrune*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbPhkRef =
  ## Constructor
  db.new.legacyMptFn(root, true).toCoreDbPhkRef

proc phkPrune*(db: CoreDbRef; root: Hash256; prune: bool): CoreDbPhkRef =
  ## Constructor
  db.new.legacyMptFn(root, prune).toCoreDbPhkRef

proc phkPrune*(db: CoreDbRef; prune: bool): CoreDbPhkRef =
  ## Constructor
  db.new.legacyMptFn(EMPTY_ROOT_HASH, prune).toCoreDbPhkRef

# ------------------------------------------------------------------------------
# Public hexary trie switch methods
# ------------------------------------------------------------------------------

proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
  ## Getter
  mpt.toCoreDbPhkRef

proc toMpt*(trie: CoreDbPhkRef): CoreDbMptRef =
  ## Getter
  trie.parent

# ------------------------------------------------------------------------------
# Public hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc parent*(mpt: CoreDbMptRef): CoreDbRef =
  ## Getter
  mpt.parent

proc parent*(trie: CoreDbPhkRef): CoreDbRef =
  ## Getter
  trie.parent.parent

proc isPruning*(trie: CoreDbMptRef|CoreDbPhkRef): bool =
  ## Getter
  trie.methods.isPruningFn()

proc get*(
    trie: CoreDbMptRef|CoreDbPhkRef;
    key: openArray[byte];
      ): Blob
      {.gcsafe, raises: [RlpError].} =
  trie.methods.getFn key

proc maybeGet*(
    trie: CoreDbMptRef|CoreDbPhkRef;
    key: openArray[byte];
      ): Option[Blob]
      {.gcsafe, raises: [RlpError].} =
  trie.methods.maybeGetFn key

proc del*(
    trie: CoreDbMptRef|CoreDbPhkRef;
    key: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  trie.methods.delFn key

proc put*(
    trie: CoreDbMptRef|CoreDbPhkRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.gcsafe, raises: [RlpError].} =
  trie.methods.putFn(key, value)

proc contains*(
    trie: CoreDbMptRef|CoreDbPhkRef;
    key: openArray[byte];
      ): bool
      {.gcsafe, raises: [RlpError].} =
  trie.methods.containsFn key

proc rootHash*(
    trie: CoreDbMptRef|CoreDbPhkRef;
      ): Hash256
      {.gcsafe.} =
  trie.methods.rootHashFn()

iterator pairs*(
    trie: CoreDbMptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  ## Trie traversal, only supported for `CoreDbMptRef`
  for k,v in trie.methods.pairsIt():
    yield (k,v)

iterator replicate*(
    trie: CoreDbMptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  ## Low level trie dump, only supported for `CoreDbMptRef`
  for k,v in trie.methods.replicateIt():
    yield (k,v)

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc getTransactionID*(db: CoreDbRef): CoreDbTxID  =
  ## Getter, current transaction state
  db.new.getIdFn()

proc parent*(id: CoreDbTxID): CoreDbRef =
  ## Getter
  id.parent

proc setTransactionID*(id: CoreDbTxID) =
  ## Setter, revert to some earlier transaction state
  id.methods.setIdFn()

proc shortTimeReadOnly*(
    id: CoreDbTxID;
    action: proc() {.gcsafe, raises: [CatchableError].};
      ) {.gcsafe, raises: [CatchableError].} =
  ## Run `action()` in an earlier transaction environment.
  id.methods.roWrapperFn action


proc beginTransaction*(db: CoreDbRef): CoreDbTxRef =
  ## Constructor
  db.new.beginFn()

proc parent*(db: CoreDbTxRef): CoreDbRef =
  ## Getter
  db.parent

proc commit*(tx: CoreDbTxRef, applyDeletes = true) =
  tx.methods.commitFn applyDeletes

proc rollback*(tx: CoreDbTxRef) =
  tx.methods.rollbackFn()

proc dispose*(tx: CoreDbTxRef) =
  tx.methods.disposeFn()

proc safeDispose*(tx: CoreDbTxRef)  =
  tx.methods.safeDisposeFn()

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc capture*(db: CoreDbRef; flags: set[CoreDbCaptFlags] = {}): CoreDbCaptRef =
  ## Constructor
  db.new.captureFn flags

proc parent*(db: CoreDbCaptRef): CoreDbRef =
  ## Getter
  db.parent

proc recorder*(db: CoreDbCaptRef): CoreDbRef =
  ## Getter
  db.methods.recorderFn()

proc flags*(db: CoreDbCaptRef): set[CoreDbCaptFlags] =
  ## Getter
  db.methods.getFlagsFn()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
