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
  ../../constants,
  ./base/[base_desc, validate]

export
  CoreDbCaptFlags,
  CoreDbCaptRef,
  CoreDbKvtObj,
  CoreDbMptRef,
  CoreDbPhkRef,
  CoreDbRef,
  CoreDbTxID,
  CoreDbTxRef,
  CoreDbType
 
logScope:
  topics = "core_db-base"

when defined(release):
  const AutoValidateDescriptors = false
else:
  const AutoValidateDescriptors = true

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   rlpRaise, gcsafe, raises: [RlpError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

type
  CoreDbTrieRef* = CoreDbMptRef | CoreDbPhkRef
    ## Shortcut, *MPT* modules

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb " & info

template itNotImplemented(db: CoreDbRef, name: string) =
  warn logTxt "iterator not implemented", dbType=db.kvtObj.dbType, meth=name

# ---------

func toCoreDbPhkRef(mpt: CoreDbMptRef): CoreDbPhkRef =
  ## MPT => pre-hashed MPT (aka PHK)
  result = CoreDbPhkRef(
    fromMpt: mpt,
    methods: mpt.methods)

  result.methods.getFn =
    proc(k: openArray[byte]): Blob {.rlpRaise.} =
      mpt.methods.getFn(k.keccakHash.data)

  result.methods.maybeGetFn =
    proc(k: openArray[byte]): Option[Blob] {.rlpRaise.} =
      mpt.methods.maybeGetFn(k.keccakHash.data)

  result.methods.delFn =
    proc(k: openArray[byte]) {.rlpRaise.} =
      mpt.methods.delFn(k.keccakHash.data)

  result.methods.putFn =
    proc(k:openArray[byte]; v:openArray[byte]) {.catchRaise.} =
      mpt.methods.putFn(k.keccakHash.data, v)

  result.methods.containsFn =
    proc(k: openArray[byte]): bool {.rlpRaise.} =
      mpt.methods.containsFn(k.keccakHash.data)

  result.methods.pairsIt =
    iterator(): (Blob, Blob) {.noRaise.} =
      mpt.parent.itNotImplemented("pairs/phk")

  result.methods.replicateIt =
    iterator(): (Blob, Blob) {.noRaise.} =
      mpt.parent.itNotImplemented("replicate/phk")

  when AutoValidateDescriptors:
    result.validate

proc kvtUpdate(db: CoreDbRef) =
  ## Disable interator for non-memory instances
  case db.kvtObj.dbType
  of LegacyDbMemory:
    discard
  else:
    db.kvtObj.methods.pairsIt = iterator(): (Blob, Blob) =
      db.itNotImplemented "pairs/kvt"

func parent(phk: CoreDbPhkRef): CoreDbRef =
  phk.fromMpt.parent

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    db:         CoreDbRef;                # Main descriptor, locally extended
    dbType:     CoreDbType;               # Backend symbol
    dbMethods:  CoreDbMiscFns;            # General methods
    kvtMethods: CoreDbKvtFns;             # Kvt related methods
    new:        CoreDbConstructors;       # Sub-module constructors
     ) =
  ## Base descriptor initaliser
  db.methods = dbMethods
  db.new = new

  db.kvtObj.dbType = dbType
  db.kvtObj.methods = kvtMethods
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
  db.kvtObj.dbType

# On the persistent legacy hexary trie, this function is needed for
# bootstrapping and Genesis setup when the `purge` flag is activated.
proc compensateLegacySetup*(db: CoreDbRef) =
  db.methods.legacySetupFn()

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

proc kvt*(db: CoreDbRef): CoreDbKvtObj =
  ## Getter (pseudo constructor)
  db.kvtObj

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

proc mpt*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbMptRef {.catchRaise.} =
  ## Constructor
  db.new.mptFn root

proc mptPrune*(
    db: CoreDbRef;
    root=EMPTY_ROOT_HASH;
      ): CoreDbMptRef
      {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(root, true)

proc mptPrune*(
    db: CoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbMptRef
      {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(root, prune)

proc mptPrune*(db: CoreDbRef; prune: bool): CoreDbMptRef {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(EMPTY_ROOT_HASH, prune)

# ------------------------------------------------------------------------------
# Public pre-hashed key hexary trie constructors
# ------------------------------------------------------------------------------

proc phk*(db: CoreDbRef; root=EMPTY_ROOT_HASH): CoreDbPhkRef {.catchRaise.} =
  ## Constructor
  db.new.mptFn(root).toCoreDbPhkRef

proc phkPrune*(
    db: CoreDbRef;
    root=EMPTY_ROOT_HASH;
      ): CoreDbPhkRef
      {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(root, true).toCoreDbPhkRef

proc phkPrune*(
    db: CoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbPhkRef
      {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(root, prune).toCoreDbPhkRef

proc phkPrune*(db: CoreDbRef; prune: bool): CoreDbPhkRef {.catchRaise.} =
  ## Constructor
  db.new.legacyMptFn(EMPTY_ROOT_HASH, prune).toCoreDbPhkRef

# ------------------------------------------------------------------------------
# Public hexary trie switch methods
# ------------------------------------------------------------------------------

proc toPhk*(mpt: CoreDbMptRef): CoreDbPhkRef =
  ## Replaces argument `mpt` by a pre-hashed *MPT*. The argment `mpt` should
  ## not be used, anymore.
  mpt.toCoreDbPhkRef

proc toMpt*(phk: CoreDbPhkRef): CoreDbMptRef =
  ## Replaces the pre-hashed argument trie `phk` by the non pre-hashed *MPT*.
  ## The argment `phk` should not be used, anymore.
  ## not be used, anymore.
  phk.fromMpt

# ------------------------------------------------------------------------------
# Public hexary trie database methods (`mpt` or `phk`)
# ------------------------------------------------------------------------------

proc parent*(trie: CoreDbTrieRef): CoreDbRef =
  ## Getter
  trie.parent

proc isPruning*(trie: CoreDbTrieRef): bool =
  ## Getter
  trie.methods.isPruningFn()

proc get*(trie: CoreDbTrieRef; key: openArray[byte]): Blob {.rlpRaise.} =
  trie.methods.getFn(key)

proc maybeGet*(
    trie: CoreDbTrieRef;
    key: openArray[byte];
      ): Option[Blob]
      {.rlpRaise.} =
  trie.methods.maybeGetFn key

proc del*(trie: CoreDbTrieRef; key: openArray[byte]) {.rlpRaise.} =
  trie.methods.delFn key

proc put*(
    trie: CoreDbTrieRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.catchRaise.} =
  trie.methods.putFn(key, value)

proc contains*(trie: CoreDbTrieRef; key: openArray[byte]): bool {.rlpRaise.} =
  trie.methods.containsFn key

proc rootHash*(trie: CoreDbTrieRef): Hash256 {.noRaise.} =
  trie.methods.rootHashFn()

iterator pairs*(mpt: CoreDbMptRef): (Blob, Blob) {.rlpRaise.} =
  ## Trie traversal, only supported for `CoreDbMptRef`
  for k,v in mpt.methods.pairsIt():
    yield (k,v)

iterator replicate*(mpt: CoreDbMptRef): (Blob, Blob) {.catchRaise.} =
  ## Low level trie dump, only supported for `CoreDbMptRef`
  for k,v in mpt.methods.replicateIt():
    yield (k,v)

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

proc getTransactionID*(db: CoreDbRef): CoreDbTxID  {.catchRaise.} =
  ## Getter, current transaction state
  db.new.getIdFn()

proc setTransactionID*(id: CoreDbTxID) {.catchRaise.} =
  ## Setter, revert to some earlier transaction state
  id.methods.setIdFn()

proc shortTimeReadOnly*(
    id: CoreDbTxID;
    action: proc() {.catchRaise.};
      ) {.catchRaise.} =
  ## Run `action()` in an earlier transaction environment.
  id.methods.roWrapperFn action


proc beginTransaction*(db: CoreDbRef): CoreDbTxRef {.catchRaise.} =
  ## Constructor
  db.new.beginFn()

proc parent*(db: CoreDbTxRef): CoreDbRef =
  ## Getter
  db.parent

proc commit*(tx: CoreDbTxRef, applyDeletes = true) {.catchRaise.} =
  tx.methods.commitFn applyDeletes

proc rollback*(tx: CoreDbTxRef) {.catchRaise.} =
  tx.methods.rollbackFn()

proc dispose*(tx: CoreDbTxRef) {.catchRaise.} =
  tx.methods.disposeFn()

proc safeDispose*(tx: CoreDbTxRef) {.catchRaise.} =
  tx.methods.safeDisposeFn()

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

proc capture*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbCaptRef
      {.catchRaise.} =
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
