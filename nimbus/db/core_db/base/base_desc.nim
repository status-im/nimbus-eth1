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
  eth/common,
  results,
  ../../../errors

# Annotation helpers
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

type
  CoreDbType* = enum
    Ooops
    LegacyDbMemory
    LegacyDbPersistent
    # AristoDbMemory
    # AristoDbPersistent

const
  CoreDbPersistentTypes* = {LegacyDbPersistent}

type
  CoreDbRc*[T] = Result[T,CoreDbErrorRef]

  CoreDbCaptFlags* {.pure.} = enum
    PersistPut
    PersistDel

  # --------------------------------------------------
  # Constructors
  # --------------------------------------------------
  CoreDbNewMptFn* =
    proc(root: Hash256): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbNewLegaMptFn* =
    proc(root: Hash256; prune: bool): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbNewTxGetIdFn* = proc(): CoreDbRc[CoreDxTxID] {.noRaise.}
  CoreDbNewTxBeginFn* = proc(): CoreDbRc[CoreDxTxRef] {.noRaise.}
  CoreDbNewCaptFn* =
    proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] {.noRaise.}

  CoreDbConstructorFns* = object
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
  CoreDbBackendFn* = proc(): CoreDbBackendRef {.noRaise.}
  CoreDbErrorPrintFn* = proc(e: CoreDbErrorRef): string {.noRaise.}
  CoreDbInitLegaSetupFn* = proc() {.noRaise.}

  CoreDbMiscFns* = object
    backendFn*:     CoreDbBackendFn
    errorPrintFn*:  CoreDbErrorPrintFn
    legacySetupFn*: CoreDbInitLegaSetupFn


  # --------------------------------------------------
  # Sub-descriptor: KVT methods
  # --------------------------------------------------
  CoreDbKvtBackendFn* = proc(): CoreDbKvtBackendRef {.noRaise.}
  CoreDbKvtGetFn* = proc(k: openArray[byte]): CoreDbRc[Blob] {.noRaise.} 
  CoreDbKvtDelFn* = proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtPutFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtContainsFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbKvtPairsIt* = iterator(): (Blob,Blob) {.apiRaise.}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    backendFn*:  CoreDbKvtBackendFn
    getFn*:      CoreDbKvtGetFn
    delFn*:      CoreDbKvtDelFn
    putFn*:      CoreDbKvtPutFn
    containsFn*: CoreDbKvtContainsFn
    pairsIt*:    CoreDbKvtPairsIt


  # --------------------------------------------------
  # Sub-descriptor: Mpt/hexary trie methods
  # --------------------------------------------------
  CoreDbMptBackendFn* = proc(): CoreDbMptBackendRef {.noRaise.}
  CoreDbMptGetFn* =
    proc(k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbMptDelFn* =
    proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbMptPutFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void ] {.noRaise.}
  CoreDbMptContainsFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbMptRootHashFn* = proc(): CoreDbRc[Hash256] {.noRaise.}
  CoreDbMptIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbMptPairsIt* = iterator(): (Blob,Blob) {.apiRaise.}
  CoreDbMptReplicateIt* = iterator(): (Blob,Blob) {.apiRaise.}

  CoreDbMptFns* = object
    ## Methods for trie objects
    backendFn*:   CoreDbMptBackendFn
    getFn*:       CoreDbMptGetFn
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
  CoreDbTxCommitFn* = proc(applyDeletes: bool): CoreDbRc[void] {.noRaise.}
  CoreDbTxRollbackFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbTxDisposeFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbTxSafeDisposeFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbTxFns* = object
    commitFn*:      CoreDbTxCommitFn
    rollbackFn*:    CoreDbTxRollbackFn
    disposeFn*:     CoreDbTxDisposeFn
    safeDisposeFn*: CoreDbTxSafeDisposeFn

  # --------------------------------------------------
  # Sub-descriptor: Transaction ID management
  # --------------------------------------------------
  CoreDbTxIdSetIdFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbTxIdActionFn* = proc() {.noRaise.}
  CoreDbTxIdRoWrapperFn* =
    proc(action: CoreDbTxIdActionFn): CoreDbRc[void] {.noRaise.}
  CoreDbTxIdFns* = object
    roWrapperFn*: CoreDbTxIdRoWrapperFn


  # --------------------------------------------------
  # Sub-descriptor: capture recorder methods
  # --------------------------------------------------
  CoreDbCaptRecorderFn* = proc(): CoreDbRc[CoreDbRef] {.noRaise.}
  CoreDbCaptFlagsFn* = proc(): set[CoreDbCaptFlags] {.noRaise.}

  CoreDbCaptFns* = object
    recorderFn*: CoreDbCaptRecorderFn
    getFlagsFn*: CoreDbCaptFlagsFn

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    dbType*: CoreDbType
    kvtRef*: CoreDxKvtRef
    new*: CoreDbConstructorFns
    methods*: CoreDbMiscFns

  CoreDbErrorRef* = ref object of RootRef
    ## Generic error object
    parent*: CoreDbRef

  CoreDbBackendRef* = ref object of RootRef
    ## Backend wrapper for direct backend access
    parent*: CoreDbRef

  CoreDbKvtBackendRef* = ref object of RootRef
    ## Backend wrapper for direct backend access
    parent*: CoreDbRef

  CoreDbMptBackendRef* = ref object of RootRef
    ## Backend wrapper for direct backend access
    parent*: CoreDbRef

  CoreDxKvtRef* = ref object
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbKvtFns

  CoreDxMptRef* = ref object
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent*: CoreDbRef
    methods*: CoreDbMptFns

  CoreDxPhkRef* = ref object
    ## Similar to `CoreDbMptRef` but with pre-hashed keys. That is, any
    ## argument key for `put()`, `get()` etc. will be hashed first before
    ## being applied.
    fromMpt*: CoreDxMptRef
    methods*: CoreDbMptFns

  CoreDxTxRef* = ref object
    ## Transaction descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbTxFns

  CoreDxTxID* = ref object
    ## Transaction ID descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbTxIdFns

  CoreDxCaptRef* = ref object
    ## Db transaction tracer derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbCaptFns

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
