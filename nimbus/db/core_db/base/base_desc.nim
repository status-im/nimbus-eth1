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
  eth/common,
  results,
  ../../storage_types,
  ../../aristo/aristo_profile

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
  CoreDbProfListRef* = AristoDbProfListRef
    ## Borrowed from `aristo_profile`, only used in profiling mode

  CoreDbProfData* = AristoDbProfData
    ## Borrowed from `aristo_profile`, only used in profiling mode

  CoreDbRc*[T] = Result[T,CoreDbErrorRef]

  CoreDbAccount* = object
    ## Generic account representation referencing an *MPT* sub-trie
    address*:  EthAddress    ## Reverse reference for storage trie path
    nonce*:    AccountNonce  ## Some `uint64` type
    balance*:  UInt256
    stoTrie*:  CoreDbTrieRef ## Implies storage root sub-MPT
    codeHash*: Hash256

  CoreDbErrorCode* = enum
    Unset = 0
    Unspecified
    RlpException
    KvtNotFound
    KvtTxPending
    MptNotFound
    MptTxPending
    AccNotFound
    AccAddrMissing
    AccTxPending
    RootNotFound
    AutoFlushFailed
    RootUnacceptable
    HashNotAvailable
    TrieLocked
    StorageFailed

  CoreDbSubTrie* = enum
    StorageTrie = 0
    AccountsTrie
    GenericTrie
    ReceiptsTrie
    TxTrie
    WithdrawalsTrie

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
  CoreDbBaseVerifyFn* = proc(trie: CoreDbTrieRef): bool {.noRaise.}
  CoreDbBaseBackendFn* = proc(): CoreDbBackendRef {.noRaise.}
  CoreDbBaseDestroyFn* = proc(flush = true) {.noRaise.}
  CoreDbBaseTryHashFn* = proc(vid: CoreDbTrieRef): CoreDbRc[Hash256] {.noRaise.}
  CoreDbBaseRootHashFn* = proc(
    trie: CoreDbTrieRef): CoreDbRc[Hash256] {.noRaise.}
  CoreDbBaseTriePrintFn* = proc(vid: CoreDbTrieRef): string {.noRaise.}
  CoreDbBaseErrorPrintFn* = proc(e: CoreDbErrorRef): string {.noRaise.}
  CoreDbBaseInitLegaSetupFn* = proc() {.noRaise.}
  CoreDbBaseGetTrieFn* = proc(
    trie: CoreDbSubTrie; root: Hash256; address: Option[EthAddress];
    ): CoreDbRc[CoreDbTrieRef] {.noRaise.}
  CoreDbBaseLevelFn* = proc(): int {.noRaise.}
  CoreDbBaseKvtFn* = proc(
    namespace: DbNamespace, saveMode: CoreDbSaveFlags): CoreDbRc[CoreDxKvtRef] {.noRaise.}
  CoreDbBaseMptFn* = proc(
    root: CoreDbTrieRef; prune: bool; saveMode: CoreDbSaveFlags;
    ): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbBaseAccFn* = proc(
    root: CoreDbTrieRef; prune: bool; saveMode: CoreDbSaveFlags;
    ): CoreDbRc[CoreDxAccRef] {.noRaise.}
  CoreDbBaseTxGetIdFn* = proc(): CoreDbRc[CoreDxTxID] {.noRaise.}
  CoreDbBaseTxBeginFn* = proc(): CoreDbRc[CoreDxTxRef] {.noRaise.}
  CoreDbBaseCaptFn* =
    proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] {.noRaise.}

  CoreDbBaseFns* = object
    verifyFn*:      CoreDbBaseVerifyFn
    backendFn*:     CoreDbBaseBackendFn
    destroyFn*:     CoreDbBaseDestroyFn
    tryHashFn*:     CoreDbBaseTryHashFn
    rootHashFn*:    CoreDbBaseRootHashFn
    triePrintFn*:   CoreDbBaseTriePrintFn
    errorPrintFn*:  CoreDbBaseErrorPrintFn
    legacySetupFn*: CoreDbBaseInitLegaSetupFn
    getTrieFn*:     CoreDbBaseGetTrieFn
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
  CoreDbKvtNamespaceFn* = proc(ns: DbNamespace): CoreDxKvtRef {.noRaise.}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    backendFn*:    CoreDbKvtBackendFn
    getFn*:        CoreDbKvtGetFn
    delFn*:        CoreDbKvtDelFn
    putFn*:        CoreDbKvtPutFn
    hasKeyFn*:     CoreDbKvtHasKeyFn
    persistentFn*: CoreDbKvtPersistentFn
    forgetFn*:     CoreDbKvtForgetFn
    namespaceFn*:  CoreDbKvtNamespaceFn


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
  CoreDbMptGetTrieFn* = proc(): CoreDbTrieRef {.noRaise.}
  CoreDbMptIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbMptPersistentFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbMptForgetFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbMptFns* = object
    ## Methods for trie objects
    backendFn*:    CoreDbMptBackendFn
    fetchFn*:      CoreDbMptFetchFn
    deleteFn*:     CoreDbMptDeleteFn
    mergeFn*:      CoreDbMptMergeFn
    hasPathFn*:    CoreDbMptHasPathFn
    getTrieFn*:    CoreDbMptGetTrieFn
    isPruningFn*:  CoreDbMptIsPruningFn
    persistentFn*: CoreDbMptPersistentFn
    forgetFn*:     CoreDbMptForgetFn

  # ----------------------------------------------------
  # Sub-descriptor: Mpt/hexary trie methods for accounts
  # ------------------------------------------------------
  CoreDbAccBackendFn* = proc(): CoreDbAccBackendRef {.noRaise.}
  CoreDbAccNewMptFn* = proc(): CoreDbRc[CoreDxMptRef] {.noRaise.}
  CoreDbAccFetchFn* = proc(k: EthAddress): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbAccDeleteFn* = proc(k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccStoFlushFn* = proc(k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccMergeFn* = proc(v: CoreDbAccount): CoreDbRc[void] {.noRaise.}
  CoreDbAccHasPathFn* = proc(k: EthAddress): CoreDbRc[bool] {.noRaise.}
  CoreDbAccGetTrieFn* = proc(): CoreDbTrieRef {.noRaise.}
  CoreDbAccIsPruningFn* = proc(): bool {.noRaise.}
  CoreDbAccPersistentFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbAccForgetFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbAccFns* = object
    ## Methods for trie objects
    backendFn*:    CoreDbAccBackendFn
    newMptFn*:     CoreDbAccNewMptFn
    fetchFn*:      CoreDbAccFetchFn
    deleteFn*:     CoreDbAccDeleteFn
    stoFlushFn*:   CoreDbAccStoFlushFn
    mergeFn*:      CoreDbAccMergeFn
    hasPathFn*:    CoreDbAccHasPathFn
    getTrieFn*:    CoreDbAccGetTrieFn
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
    dbType*: CoreDbType         ## Type of database backend
    trackLegaApi*: bool         ## Debugging, support
    trackNewApi*: bool          ## Debugging, support
    trackLedgerApi*: bool       ## Debugging, suggestion for subsequent ledger
    localDbOnly*: bool          ## Debugging, suggestion to ignore async fetch
    profTab*: CoreDbProfListRef ## Profiling data (if any)
    ledgerHook*: RootRef        ## Debugging/profiling, to be used by ledger
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

  CoreDbTrieRef* = ref object of RootRef
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
