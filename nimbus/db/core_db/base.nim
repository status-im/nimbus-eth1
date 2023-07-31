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
  eth/common

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

  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    kvt: CoreDbKvtRef

  CoreDbKvtRef* = ref object of RootRef
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    dbType: CoreDbType

  CoreDbMptRef* = ref object of RootRef
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent: CoreDbRef

  CoreDbPhkRef* = ref object of RootRef
    ## Similar to `CoreDbMptRef` but with pre-hashed keys. That is, any
    ## argument key for `put()`, `get()` etc. will be hashed first before
    ## being applied.
    parent: CoreDbRef

  CoreDbCaptRef* = ref object of RootRef
    ## Db transaction tracer derived from `CoreDbRef`
    parent: CoreDbRef
    flags: set[CoreDbCaptFlags]

  CoreDbTxRef* = ref object of RootRef
    ## Transaction descriptor derived from `CoreDbRef`
    parent: CoreDbRef

  CoreDbTxID* = ref object of RootRef

logScope:
  topics = "core_db-base"

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "CoreDb base: " & info

proc notImplemented(db: CoreDbKvtRef, name: string) {.used.} =
  debug logTxt "method not implemented", dbType=db.dbType, meth=name

proc notImplemented(db: CoreDbRef, name: string) {.used.} =
  db.kvt.notImplemented name

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(db: CoreDbRef; dbType: CoreDbType; kvt: CoreDbKvtRef) =
  db.kvt = kvt
  kvt.dbType = dbType

proc init*(db: CoreDbTxRef|CoreDbMptRef|CoreDbPhkRef; parent: CoreDbRef) =
  db.parent = parent

proc init*(db: CoreDbCaptRef; parent: CoreDbRef; flags: set[CoreDbCaptFlags]) =
  db.parent = parent
  db.flags = flags

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc dbType*(db: CoreDbRef): CoreDbType =
  db.kvt.dbType

proc dbType*(db: CoreDbKvtRef): CoreDbType =
  db.dbType

proc kvt*(db: CoreDbRef): CoreDbKvtRef =
  db.kvt

proc parent*(
    db: CoreDbTxRef|CoreDbMptRef|CoreDbPhkRef|CoreDbCaptRef;
      ): CoreDbRef =
  db.parent

proc flags*(db: CoreDbCaptRef): set[CoreDbCaptFlags] =
  db.flags

# ------------------------------------------------------------------------------
# Public legacy helpers
# ------------------------------------------------------------------------------

# On the persistent legacy hexary trie, this function is needed for
# bootstrapping and Genesis setup when the `purge` flag is activated.
method compensateLegacySetup*(db: CoreDbRef) {.base.} =
  db.notImplemented "compensateLegacySetup"

# ------------------------------------------------------------------------------
# Public tracer methods
# ------------------------------------------------------------------------------

method newCoreDbCaptRef*(
    db: CoreDbRef;
    flags: set[CoreDbCaptFlags] = {};
      ): CoreDbCaptRef
      {.base.} =
  ## Start capture session on the argument `db`
  db.notImplemented "newCaptureRef"

method recorder*(
    db: CoreDbCaptRef;
      ): CoreDbRef
      {.base.} =
  ## Retrieve recording database descriptor
  db.parent.notImplemented "db"

# ------------------------------------------------------------------------------
# Public key-value table methods
# ------------------------------------------------------------------------------

method get*(
    db: CoreDbKvtRef;
    key: openArray[byte];
      ): Blob
      {.base.} =
  db.notImplemented "get/kvt"

method maybeGet*(
    db: CoreDbKvtRef;
    key: openArray[byte];
      ): Option[Blob]
      {.base.} =
  db.notImplemented "maybeGet/kvt"

method del*(
    db: CoreDbKvtRef;
    key: openArray[byte];
      ) {.base.} =
  db.notImplemented "del/kvt"

method put*(
    db: CoreDbKvtRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.base.} =
  db.notImplemented "put/kvt"

method contains*(
    db: CoreDbKvtRef;
    key: openArray[byte];
      ): bool
      {.base.} =
  db.notImplemented "contains/kvt"

# ------------------------------------------------------------------------------
# Public hexary trie methods
# ------------------------------------------------------------------------------

method mpt*(
    db: CoreDbRef;
    root: Hash256;
      ): CoreDbMptRef
      {.base.} =
  db.notImplemented "mpt"

method mpt*(
    db: CoreDbRef;
      ): CoreDbMptRef
      {.base.} =
  db.notImplemented "mpt"

method isPruning*(
    db: CoreDbMptRef;
      ): bool
      {.base.} =
  db.parent.notImplemented "isPruning"

# -----

method mptPrune*(
    db: CoreDbRef;
    root: Hash256;
      ): CoreDbMptRef
      {.base.} =
  ## Legacy mode MPT, will go away
  db.notImplemented "mptPrune"

method mptPrune*(
    db: CoreDbRef;
      ): CoreDbMptRef
      {.base.} =
  ## Legacy mode MPT, will go away
  db.notImplemented "mptPrune"

method mptPrune*(
    db: CoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbMptRef
      {.base.} =
  ## Legacy mode MPT, will go away
  db.notImplemented "mptPrune"

method mptPrune*(
    db: CoreDbRef;
    prune: bool;
      ): CoreDbMptRef
      {.base.} =
  ## Legacy mode MPT, will go away
  db.notImplemented "mptPrune"

# -----

{.push hint[XCannotRaiseY]: off.}

method get*(
    db: CoreDbMptRef;
    key: openArray[byte];
      ): Blob
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "get/mpt"

method maybeGet*(
    db: CoreDbMptRef;
    key: openArray[byte];
      ): Option[Blob]
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "maybeGet/mpt"

method del*(
    db: CoreDbMptRef;
    key: openArray[byte];
      ) {.base, raises: [RlpError].} =
  db.parent.notImplemented "del/mpt"

method put*(
    db: CoreDbMptRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.base, raises: [RlpError].} =
  db.parent.notImplemented "put/mpt"

method contains*(
    db: CoreDbMptRef;
    key: openArray[byte];
      ): bool
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "contains/mpt"

{.pop.}

method rootHash*(
    db: CoreDbMptRef;
      ): Hash256
      {.base.} =
  db.parent.notImplemented "rootHash/mpt"

# ------------------------------------------------------------------------------
# Public pre-kashed key hexary trie methods
# ------------------------------------------------------------------------------

method phk*(
    db: CoreDbRef;
    root: Hash256;
      ): CoreDbPhkRef
      {.base.} =
  db.notImplemented "phk"

method phk*(
    db: CoreDbRef;
      ): CoreDbPhkRef
      {.base.} =
  db.notImplemented "phk"

method isPruning*(
    db: CoreDbPhkRef;
      ): bool
      {.base.} =
  db.parent.notImplemented "isPruning"

# -----------

method phkPrune*(
    db: CoreDbRef;
    root: Hash256;
      ): CoreDbPhkRef
      {.base.} =
  ## Legacy mode PHK, will go away
  db.notImplemented "phkPrune"

method phkPrune*(
    db: CoreDbRef;
      ): CoreDbPhkRef
      {.base.} =
  ## Legacy mode PHK, will go away
  db.notImplemented "phkPrune"

method phkPrune*(
    db: CoreDbRef;
    root: Hash256;
    prune: bool;
      ): CoreDbPhkRef
      {.base.} =
  ## Legacy mode PHK, will go away
  db.notImplemented "phkPrune"

method phkPrune*(
    db: CoreDbRef;
    prune: bool;
      ): CoreDbPhkRef
      {.base.} =
  ## Legacy mode PHK, will go away
  db.notImplemented "phkPrune"

# -----------

{.push hint[XCannotRaiseY]: off.}

method get*(
    db: CoreDbPhkRef;
    key: openArray[byte];
      ): Blob
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "get/phk"

method maybeGet*(
    db: CoreDbPhkRef;
    key: openArray[byte];
      ): Option[Blob]
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "maybeGet/phk"

method del*(
    db: CoreDbPhkRef;
    key: openArray[byte];
      ) {.base, raises: [RlpError].} =
  db.parent.notImplemented "del/phk"

method put*(
    db: CoreDbPhkRef;
    key: openArray[byte];
    value: openArray[byte];
      ) {.base, raises: [RlpError].} =
  db.parent.notImplemented "put/phk"

method contains*(
    db: CoreDbPhkRef;
    key: openArray[byte];
      ): bool
      {.base, raises: [RlpError].} =
  db.parent.notImplemented "contains/phk"

{.pop.}

method rootHash*(
    db: CoreDbPhkRef;
      ): Hash256
      {.base.} =
  db.parent.notImplemented "rootHash/phk"

# ------------------------------------------------------------------------------
# Public transaction related methods
# ------------------------------------------------------------------------------

method getTransactionID*(db: CoreDbRef): CoreDbTxID {.base.} =
  db.notImplemented "getTxID"

method setTransactionID*(db: CoreDbRef; id: CoreDbTxID) {.base.} =
  db.notImplemented "setTxID"

method beginTransaction*(db: CoreDbRef): CoreDbTxRef {.base.} =
  db.notImplemented "beginTransaction"

method commit*(t: CoreDbTxRef, applyDeletes = true) {.base.} =
  t.parent.notImplemented "commit"

method rollback*(t: CoreDbTxRef) {.base.} =
  t.parent.notImplemented "rollback"

method dispose*(t: CoreDbTxRef) {.base.} =
  t.parent.notImplemented "dispose"

method safeDispose*(t: CoreDbTxRef) {.base.} =
  t.parent.notImplemented "safeDispose"

{.push hint[XCannotRaiseY]: off.}

method shortTimeReadOnly*(
    db: CoreDbRef;
    id: CoreDbTxID;
    action: proc() {.gcsafe, raises: [CatchableError].};
      ) {.base, raises: [CatchableError].} =
  db.notImplemented "shortTimeReadOnly"

{.pop.}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
