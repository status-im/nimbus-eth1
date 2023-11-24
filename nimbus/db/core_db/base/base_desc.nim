# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
    AristoDbMemory            ## Memory backend emulator
    AristoDbRocks             ## RocksDB backend
    AristoDbVoid              ## No backend

const
  CoreDbPersistentTypes* = {LegacyDbPersistent, AristoDbRocks}

type
  CoreDbRc*[T] = Result[T,CoreDbErrorRef]

  CoreDbAccount* = object
    ## Generic account representation referencing an *MPT* sub-trie
    nonce*:      AccountNonce ## Some `uint64` type
    balance*:    UInt256
    storageVid*: CoreDbVidRef ## Implies storage root sub-MPT
    codeHash*:   Hash256

  CoreDbErrorCode* = enum
    Unset = 0
    Unspecified
    RlpException
    KvtNotFound
    KvtTxPending
    MptNotFound
    MptTxPending
    AccNotFound
    AccTxPending
    RootNotFound
    RootUnacceptable
    RootCannotCreate
    HashNotAvailable
    StorageFailed

  CoreDbSaveFlags* = enum
    Shared                    ## Shared, leaves changes in memory cache
    AutoSave                  ## Shared, save changes on destruction
    TopShot                   ## Separate copy of shared cache
    Companion                 ## Separate clean cache

  CoreDbCaptFlags* {.pure.} = enum
    PersistPut
    PersistDel

  # --------------------------------------------------
  # Sub-descriptor: Misc methods for main descriptor
  # --------------------------------------------------
  CoreDbBaseBackendFn* = proc(): CoreDbBackendRef {.noRaise.}
  CoreDbBaseDestroyFn* = proc(flush = true) {.noRaise.}
  CoreDbBaseVidHashFn* =
    proc(vid: CoreDbVidRef; update: bool): CoreDbRc[Hash256] {.noRaise.}
  CoreDbBaseErrorPrintFn* = proc(e: CoreDbErrorRef): string {.noRaise.}
  CoreDbBaseInitLegaSetupFn* = proc() {.noRaise.}
  CoreDbBaseRootFn* =
    proc(root: Hash256; createOk: bool): CoreDbRc[CoreDbVidRef] {.noRaise.}
  CoreDbBaseLevelFn* = proc(): int {.noRaise.}
  CoreDbBaseKvtFn* = proc(
    saveMode: CoreDbSaveFlags): CoreDbRc[CoreDxKvtRef] {.noRaise.}
  CoreDbBaseMptFn* = proc(
    root: CoreDbVidRef; prune: bool; saveMode: CoreDbSaveFlags;
    ): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbBaseAccFn* = proc(
    root: CoreDbVidRef; prune: bool; saveMode: CoreDbSaveFlags;
    ): CoreDbRc[CoreDxAccRef] {.noRaise.}
  CoreDbBaseTxGetIdFn* = proc(): CoreDbRc[CoreDxTxID] {.noRaise.}
  CoreDbBaseTxBeginFn* = proc(): CoreDbRc[CoreDxTxRef] {.noRaise.}
  CoreDbBaseCaptFn* =
    proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] {.noRaise.}

  CoreDbBaseFns* = object
    backendFn*:     CoreDbBaseBackendFn
    destroyFn*:     CoreDbBaseDestroyFn
    vidHashFn*:     CoreDbBaseVidHashFn
    errorPrintFn*:  CoreDbBaseErrorPrintFn
    legacySetupFn*: CoreDbBaseInitLegaSetupFn
    getRootFn*:     CoreDbBaseRootFn
    levelFn*:       CoreDbBaseLevelFn

    # Kvt constructor
    newKvtFn*:      CoreDbBaseKvtFn

    # Hexary trie constructors
    newMptFn*:      CoreDbBaseMptFn
    newAccFn*:      CoreDbBaseAccFn

    # Transactions constructors
    getIdFn*:       CoreDbBaseTxGetIdFn
    beginFn*:       CoreDbBaseTxBeginFn

    # capture/tracer constructors
    captureFn*:     CoreDbBaseCaptFn


  # --------------------------------------------------
  # Sub-descriptor: KVT methods
  # --------------------------------------------------
  CoreDbKvtBackendFn* = proc(): CoreDbKvtBackendRef {.noRaise.}
  CoreDbKvtGetFn* = proc(k: openArray[byte]): CoreDbRc[Blob] {.noRaise.} 
  CoreDbKvtDelFn* = proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtPutFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtPersistentFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbKvtForgetFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbKvtHasKeyFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbKvtPairsIt* = iterator(): (Blob,Blob) {.apiRaise.}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    backendFn*:    CoreDbKvtBackendFn
    getFn*:        CoreDbKvtGetFn
    delFn*:        CoreDbKvtDelFn
    putFn*:        CoreDbKvtPutFn
    hasKeyFn*:     CoreDbKvtHasKeyFn
    persistentFn*: CoreDbKvtPersistentFn
    forgetFn*:     CoreDbKvtForgetFn
    pairsIt*:      CoreDbKvtPairsIt


  # --------------------------------------------------
  # Sub-descriptor: generic  Mpt/hexary trie methods
  # --------------------------------------------------
  CoreDbMptBackendFn* = proc(): CoreDbMptBackendRef {.noRaise.}
  CoreDbMptFetchFn* =
    proc(k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbMptFetchAccountFn* =
    proc(k: openArray[byte]): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbMptDeleteFn* =
    proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbMptMergeFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbMptMergeAccountFn* =
    proc(k: openArray[byte]; v: CoreDbAccount): CoreDbRc[void] {.noRaise.}
  CoreDbMptHasPathFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbMptRootVidFn* = proc(): CoreDbVidRef {.noRaise.}
  CoreDbMptIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbMptPersistentFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbMptForgetFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbMptPairsIt* = iterator(): (Blob,Blob) {.apiRaise.}
  CoreDbMptReplicateIt* = iterator(): (Blob,Blob) {.apiRaise.}

  CoreDbMptFns* = object
    ## Methods for trie objects
    backendFn*:    CoreDbMptBackendFn
    fetchFn*:      CoreDbMptFetchFn
    deleteFn*:     CoreDbMptDeleteFn
    mergeFn*:      CoreDbMptMergeFn
    hasPathFn*:    CoreDbMptHasPathFn
    rootVidFn*:    CoreDbMptRootVidFn
    isPruningFn*:  CoreDbMptIsPruningFn
    persistentFn*: CoreDbMptPersistentFn
    forgetFn*:     CoreDbMptForgetFn
    pairsIt*:      CoreDbMptPairsIt
    replicateIt*:  CoreDbMptReplicateIt


  # ----------------------------------------------------
  # Sub-descriptor: Mpt/hexary trie methods for accounts
  # ------------------------------------------------------
  CoreDbAccBackendFn* = proc(): CoreDbAccBackendRef {.noRaise.}
  CoreDbAccNewMptFn* = proc(): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbAccFetchFn* = proc(k: EthAddress): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbAccDeleteFn* = proc(k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccMergeFn* =
    proc(k: EthAddress; v: CoreDbAccount): CoreDbRc[void] {.noRaise.}
  CoreDbAccHasPathFn* = proc(k: EthAddress): CoreDbRc[bool] {.noRaise.}
  CoreDbAccRootVidFn* = proc(): CoreDbVidRef {.noRaise.}
  CoreDbAccIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbAccPersistentFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbAccForgetFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbAccFns* = object
    ## Methods for trie objects
    backendFn*:    CoreDbAccBackendFn
    newMptFn*:     CoreDbAccNewMptFn
    fetchFn*:      CoreDbAccFetchFn
    deleteFn*:     CoreDbAccDeleteFn
    mergeFn*:      CoreDbAccMergeFn
    hasPathFn*:    CoreDbAccHasPathFn
    rootVidFn*:    CoreDbAccRootVidFn
    isPruningFn*:  CoreDbAccIsPruningFn
    persistentFn*: CoreDbAccPersistentFn
    forgetFn*:     CoreDbAccForgetFn

  # --------------------------------------------------
  # Sub-descriptor: Transaction frame management
  # --------------------------------------------------
  CoreDbTxLevelFn* = proc(): int {.noRaise.}
  CoreDbTxCommitFn* = proc(applyDeletes: bool): CoreDbRc[void] {.noRaise.}
  CoreDbTxRollbackFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbTxDisposeFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbTxSafeDisposeFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbTxFns* = object
    levelFn*:       CoreDbTxLevelFn
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
  CoreDbCaptLogDbFn* = proc(): CoreDbRc[CoreDbRef] {.noRaise.}
  CoreDbCaptFlagsFn* = proc(): set[CoreDbCaptFlags] {.noRaise.}

  CoreDbCaptFns* = object
    recorderFn*: CoreDbCaptRecorderFn
    logDbFn*: CoreDbCaptLogDbFn
    getFlagsFn*: CoreDbCaptFlagsFn

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    dbType*: CoreDbType    ## Type of database backend
    trackLegaApi*: bool    ## Debugging support
    trackNewApi*: bool     ## Debugging support
    trackLedgerApi*: bool  ## Debugging suggestion for subsequent ledger
    localDbOnly*: bool     ## Debugging, suggestion to ignore async fetch
    methods*: CoreDbBaseFns

  CoreDbErrorRef* = ref object of RootRef
    ## Generic error object
    error*: CoreDbErrorCode
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

  CoreDbAccBackendRef* = ref object of RootRef
    ## Backend wrapper for direct backend access
    parent*: CoreDbRef

  CoreDxKvtRef* = ref object of RootRef
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbKvtFns

  CoreDxMptRef* = ref object of RootRef
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent*: CoreDbRef
    methods*: CoreDbMptFns

  CoreDxAccRef* = ref object of RootRef
    ## Similar to `CoreDxKvtRef`, only dealing with `CoreDbAccount` data
    ## rather than `Blob` values.
    parent*: CoreDbRef
    methods*: CoreDbAccFns

  CoreDbVidRef* = ref object of RootRef
    ## Generic state root: `Hash256` for legacy, `VertexID` for Aristo. This
    ## object makes only sense in the context od an *MPT*.
    parent*: CoreDbRef
    ready*: bool              ## Must be set `true` to enable

  CoreDxPhkRef* = ref object
    ## Similar to `CoreDbMptRef` but with pre-hashed keys. That is, any
    ## argument key for `merge()`, `fetch()` etc. will be hashed first
    ## before being applied.
    fromMpt*: CoreDxMptRef
    methods*: CoreDbMptFns

  CoreDxTxRef* = ref object of RootRef
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
