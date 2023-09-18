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
  eth/common

# Annotation helpers
{.pragma:    noRaise, gcsafe, raises: [].}
{.pragma:   rlpRaise, gcsafe, raises: [RlpError].}
{.pragma: catchRaise, gcsafe, raises: [CatchableError].}

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
  CoreDbNewMptFn* =
      proc(root: Hash256): CoreDbMptRef {.catchRaise.}
  CoreDbNewLegaMptFn* =
    proc(root: Hash256; prune: bool): CoreDbMptRef {.catchRaise.}
  CoreDbNewTxGetIdFn* = proc(): CoreDbTxID {.catchRaise.}
  CoreDbNewTxBeginFn* = proc(): CoreDbTxRef {.catchRaise.}
  CoreDbNewCaptFn* =
    proc(flgs: set[CoreDbCaptFlags]): CoreDbCaptRef {.catchRaise.}

  CoreDbConstructors* = object
    ## Constructors

    # Hexary trie
    mptFn*:       CoreDbNewMptFn
    legacyMptFn*: CoreDbNewLegaMptFn   # Legacy handler, should go away

    # Transactions
    getIdFn*:     CoreDbNewTxGetIdFn
    beginFn*:     CoreDbNewTxBeginFn

    # capture/tracer
    captureFn*:   CoreDbNewCaptFn


  # --------------------------------------------------
  # Sub-descriptor: Misc methods for main descriptor
  # --------------------------------------------------
  CoreDbInitLegaSetupFn* = proc() {.noRaise.}

  CoreDbMiscFns* = object
    legacySetupFn*: CoreDbInitLegaSetupFn


  # --------------------------------------------------
  # Sub-descriptor: KVT methods
  # --------------------------------------------------
  CoreDbKvtGetFn* = proc(k: openArray[byte]): Blob {.noRaise.}
  CoreDbKvtMaybeGetFn* = proc(key: openArray[byte]): Option[Blob] {.noRaise.}
  CoreDbKvtDelFn* = proc(k: openArray[byte]) {.noRaise.}
  CoreDbKvtPutFn* = proc(k: openArray[byte]; v: openArray[byte]) {.noRaise.}
  CoreDbKvtContainsFn* = proc(k: openArray[byte]): bool {.noRaise.}
  CoreDbKvtPairsIt* = iterator(): (Blob,Blob) {.noRaise.}

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
  CoreDbMptGetFn* = proc(k: openArray[byte]): Blob {.rlpRaise.}
  CoreDbMptMaybeGetFn* = proc(k: openArray[byte]): Option[Blob] {.rlpRaise.}
  CoreDbMptDelFn* = proc(k: openArray[byte]) {.rlpRaise.}
  CoreDbMptPutFn* = proc(k: openArray[byte]; v: openArray[byte]) {.catchRaise.}
  CoreDbMptContainsFn* = proc(k: openArray[byte]): bool {.rlpRaise.}
  CoreDbMptRootHashFn* = proc(): Hash256 {.noRaise.}
  CoreDbMptIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbMptPairsIt* = iterator(): (Blob,Blob) {.rlpRaise.}
  CoreDbMptReplicateIt* = iterator(): (Blob,Blob) {.catchRaise.}

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
  CoreDbTxCommitFn* = proc(applyDeletes: bool) {.catchRaise.}
  CoreDbTxRollbackFn* = proc() {.catchRaise.}
  CoreDbTxDisposeFn* = proc() {.catchRaise.}
  CoreDbTxSafeDisposeFn* = proc() {.catchRaise.}

  CoreDbTxFns* = object
    commitFn*:      CoreDbTxCommitFn
    rollbackFn*:    CoreDbTxRollbackFn
    disposeFn*:     CoreDbTxDisposeFn
    safeDisposeFn*: CoreDbTxSafeDisposeFn

  # --------------------------------------------------
  # Sub-descriptor: Transaction ID management
  # --------------------------------------------------
  CoreDbTxIdSetIdFn* = proc() {.catchRaise.}
  CoreDbTxIdActionFn* = proc() {.catchRaise.}
  CoreDbTxIdRoWrapperFn* = proc(action: CoreDbTxIdActionFn) {.catchRaise.}
  CoreDbTxIdFns* = object
    setIdFn*:     CoreDbTxIdSetIdFn
    roWrapperFn*: CoreDbTxIdRoWrapperFn


  # --------------------------------------------------
  # Sub-descriptor: capture recorder methods
  # --------------------------------------------------
  CoreDbCaptRecorderFn* = proc(): CoreDbRef {.noRaise.}
  CoreDbCaptFlagsFn* = proc(): set[CoreDbCaptFlags] {.noRaise.}

  CoreDbCaptFns* = object
    recorderFn*: CoreDbCaptRecorderFn
    getFlagsFn*: CoreDbCaptFlagsFn

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    kvtObj*: CoreDbKvtObj
    new*: CoreDbConstructors
    methods*: CoreDbMiscFns

  CoreDbKvtObj* = object
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    dbType*: CoreDbType
    methods*: CoreDbKvtFns

  CoreDbMptRef* = ref object
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent*: CoreDbRef
    methods*: CoreDbMptFns

  CoreDbPhkRef* = ref object
    ## Similar to `CoreDbMptRef` but with pre-hashed keys. That is, any
    ## argument key for `put()`, `get()` etc. will be hashed first before
    ## being applied.
    fromMpt*: CoreDbMptRef
    methods*: CoreDbMptFns

  CoreDbTxRef* = ref object
    ## Transaction descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbTxFns

  CoreDbTxID* = ref object
    ## Transaction ID descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbTxIdFns

  CoreDbCaptRef* = ref object
    ## Db transaction tracer derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbCaptFns

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
