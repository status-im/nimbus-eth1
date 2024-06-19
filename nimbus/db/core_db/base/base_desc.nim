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
  std/tables,
  eth/common,
  ../../aristo/aristo_profile

from ../../aristo
  import PayloadRef

# Annotation helpers
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: apiRaise, gcsafe, raises: [CoreDbApiError].}

type
  CoreDbType* = enum
    Ooops
    AristoDbMemory            ## Memory backend emulator
    AristoDbRocks             ## RocksDB backend
    AristoDbVoid              ## No backend

const
  CoreDbPersistentTypes* = {AristoDbRocks}

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
    storage*:  CoreDbColRef  ## Implies storage root MPT (aka column)
    codeHash*: Hash256

  CoreDbPayloadRef* = ref object of PayloadRef
    ## Extension of `Aristo` payload used in the tracer
    blob*: Blob              ## Serialised version for accounts data

  CoreDbErrorCode* = enum
    Unset = 0
    Unspecified

    AccAddrMissing
    AccNotFound
    AccTxPending
    AutoFlushFailed
    ColUnacceptable
    ColLocked
    CtxNotFound
    HashNotAvailable
    KvtNotFound
    MptNotFound
    NotImplemented
    RlpException
    RootNotFound
    RootUnacceptable
    StoNotFound
    StorageFailed
    TxPending

  CoreDbColType* = enum
    CtStorage = 0
    CtAccounts
    CtGeneric
    CtReceipts
    CtTxs
    CtWithdrawals

  CoreDbCaptFlags* {.pure.} = enum
    PersistPut
    PersistDel

  # --------------------------------------------------
  # Sub-descriptor: Misc methods for main descriptor
  # --------------------------------------------------
  CoreDbBaseDestroyFn* = proc(eradicate = true) {.noRaise.}
  CoreDbBaseColStateFn* = proc(
    col: CoreDbColRef): CoreDbRc[Hash256] {.noRaise.}
  CoreDbBaseColStateEmptyFn* = proc(
    col: CoreDbColRef): CoreDbRc[bool] {.noRaise.}
  CoreDbBaseColPrintFn* = proc(vid: CoreDbColRef): string {.noRaise.}
  CoreDbBaseErrorPrintFn* = proc(e: CoreDbErrorRef): string {.noRaise.}
  CoreDbBaseLevelFn* = proc(): int {.noRaise.}
  CoreDbBaseNewKvtFn* = proc(): CoreDbRc[CoreDbKvtRef] {.noRaise.}
  CoreDbBaseNewCtxFn* = proc(): CoreDbCtxRef {.noRaise.}
  CoreDbBaseNewCtxFromTxFn* = proc(
    colState: Hash256; kind: CoreDbColType): CoreDbRc[CoreDbCtxRef] {.noRaise.}
  CoreDbBaseSwapCtxFn* = proc(ctx: CoreDbCtxRef): CoreDbCtxRef {.noRaise.}
  CoreDbBaseTxBeginFn* = proc(): CoreDbTxRef {.noRaise.}
  CoreDbBaseNewCaptFn* =
    proc(flgs: set[CoreDbCaptFlags]): CoreDbRc[CoreDbCaptRef] {.noRaise.}
  CoreDbBaseGetCaptFn* = proc(): CoreDbRc[CoreDbCaptRef] {.noRaise.}
  CoreDbBasePersistentFn* =
    proc(bn: Opt[BlockNumber]): CoreDbRc[void] {.noRaise.}

  CoreDbBaseFns* = object
    destroyFn*:      CoreDbBaseDestroyFn
    colStateFn*:     CoreDbBaseColStateFn
    colStateEmptyFn*: CoreDbBaseColStateEmptyFn
    colPrintFn*:     CoreDbBaseColPrintFn
    errorPrintFn*:   CoreDbBaseErrorPrintFn
    levelFn*:        CoreDbBaseLevelFn

    # Kvt constructor
    newKvtFn*:       CoreDbBaseNewKvtFn

    # MPT context constructor
    newCtxFn*:       CoreDbBaseNewCtxFn
    newCtxFromTxFn*: CoreDbBaseNewCtxFromTxFn
    swapCtxFn*:      CoreDbBaseSwapCtxFn

    # Transactions constructors
    beginFn*:        CoreDbBaseTxBeginFn

    # Capture/tracer constructors
    newCaptureFn*:   CoreDbBaseNewCaptFn

    # Save to disk
    persistentFn*: CoreDbBasePersistentFn


  # --------------------------------------------------
  # Sub-descriptor: KVT methods
  # --------------------------------------------------
  CoreDbKvtBackendFn* = proc(): CoreDbKvtBackendRef {.noRaise.}
  CoreDbKvtGetFn* = proc(k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbKvtDelFn* = proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtPutFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtForgetFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbKvtHasKeyFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    backendFn*:     CoreDbKvtBackendFn
    getFn*:         CoreDbKvtGetFn
    delFn*:         CoreDbKvtDelFn
    putFn*:         CoreDbKvtPutFn
    hasKeyFn*:      CoreDbKvtHasKeyFn
    forgetFn*:      CoreDbKvtForgetFn

  # --------------------------------------------------
  # Sub-descriptor: MPT context methods
  # --------------------------------------------------
  CoreDbCtxFromTxFn* =
    proc(root: Hash256; kind: CoreDbColType): CoreDbRc[CoreDbCtxRef] {.noRaise.}
  CoreDbCtxNewColFn* = proc(
    colType: CoreDbColType; colState: Hash256; address: Opt[EthAddress];
    ): CoreDbRc[CoreDbColRef] {.noRaise.}
  CoreDbCtxGetMptFn* = proc(
    root: CoreDbColRef): CoreDbRc[CoreDbMptRef] {.noRaise.}
  CoreDbCtxGetAccountsFn* = proc(): CoreDbAccRef {.noRaise.}
  CoreDbCtxForgetFn* = proc() {.noRaise.}

  CoreDbCtxFns* = object
    ## Methods for context maniulation
    newColFn*:      CoreDbCtxNewColFn
    getMptFn*:      CoreDbCtxGetMptFn
    getAccountsFn*: CoreDbCtxGetAccountsFn
    forgetFn*:      CoreDbCtxForgetFn

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
  CoreDbMptGetColFn* = proc(): CoreDbColRef {.noRaise.}
  CoreDbMptForgetFn* = proc(): CoreDbRc[void] {.noRaise.}

  CoreDbMptFns* = object
    ## Methods for trie objects
    backendFn*:   CoreDbMptBackendFn
    fetchFn*:     CoreDbMptFetchFn
    deleteFn*:    CoreDbMptDeleteFn
    mergeFn*:     CoreDbMptMergeFn
    hasPathFn*:   CoreDbMptHasPathFn
    getColFn*:    CoreDbMptGetColFn


  # ----------------------------------------------------
  # Sub-descriptor: Account column methods
  # ------------------------------------------------------
  CoreDbAccBackendFn* = proc(): CoreDbAccBackendRef {.noRaise.}
  CoreDbAccFetchFn* = proc(k: EthAddress): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbAccDeleteFn* = proc(k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccClearStorageFn* = proc(k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccMergeFn* = proc(v: CoreDbAccount): CoreDbRc[void] {.noRaise.}
  CoreDbAccHasPathFn* = proc(k: EthAddress): CoreDbRc[bool] {.noRaise.}
  CoreDbAccStateFn* = proc(updateOk: bool): CoreDbRc[Hash256] {.noRaise.}

  CoreDbSlotFetchFn* =
    proc(a: EthAddress; k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbSlotDeleteFn* =
    proc(a: EthAddress; k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbSlotHasPathFn* =
    proc(a: EthAddress; k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbSlotMergeFn* =
    proc(a: EthAddress; k, v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbSlotStateFn* =
    proc(a: EthAddress; updateOk: bool): CoreDbRc[Hash256] {.noRaise.}

  CoreDbAccFns* = object
    ## Methods for trie objects
    backendFn*:      CoreDbAccBackendFn
    fetchFn*:        CoreDbAccFetchFn
    clearStorageFn*: CoreDbAccClearStorageFn
    deleteFn*:       CoreDbAccDeleteFn
    hasPathFn*:      CoreDbAccHasPathFn
    mergeFn*:        CoreDbAccMergeFn
    stateFn*:        CoreDbAccStateFn

    slotFetchFn*:    CoreDbSlotFetchFn
    slotDeleteFn*:   CoreDbSlotDeleteFn
    slotHasPathFn*:  CoreDbSlotHasPathFn
    slotMergeFn*:    CoreDbSlotMergeFn
    slotStateFn*:    CoreDbSlotStateFn


  # --------------------------------------------------
  # Sub-descriptor: Transaction frame management
  # --------------------------------------------------
  CoreDbTxLevelFn* = proc(): int {.noRaise.}
  CoreDbTxCommitFn* = proc() {.noRaise.}
  CoreDbTxRollbackFn* = proc() {.noRaise.}
  CoreDbTxDisposeFn* = proc() {.noRaise.}

  CoreDbTxFns* = object
    levelFn*:       CoreDbTxLevelFn
    commitFn*:      CoreDbTxCommitFn
    rollbackFn*:    CoreDbTxRollbackFn
    disposeFn*:     CoreDbTxDisposeFn


  # --------------------------------------------------
  # Sub-descriptor: capture recorder methods
  # --------------------------------------------------
  CoreDbCaptRecorderFn* = proc(): CoreDbRef {.noRaise.}
  CoreDbCaptLogDbFn* = proc(): TableRef[Blob,Blob] {.noRaise.}
  CoreDbCaptFlagsFn* = proc(): set[CoreDbCaptFlags] {.noRaise.}
  CoreDbCaptForgetFn* = proc() {.noRaise.}

  CoreDbCaptFns* = object
    recorderFn*: CoreDbCaptRecorderFn
    logDbFn*: CoreDbCaptLogDbFn
    getFlagsFn*: CoreDbCaptFlagsFn
    forgetFn*: CoreDbCaptForgetFn


  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    dbType*: CoreDbType         ## Type of database backend
    trackLegaApi*: bool         ## Debugging, support
    trackNewApi*: bool          ## Debugging, support
    trackLedgerApi*: bool       ## Debugging, suggestion for subsequent ledger
    profTab*: CoreDbProfListRef ## Profiling data (if any)
    ledgerHook*: RootRef        ## Debugging/profiling, to be used by ledger
    methods*: CoreDbBaseFns

  CoreDbErrorRef* = ref object of RootRef
    ## Generic error object
    error*: CoreDbErrorCode
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

  CoreDbKvtRef* = ref object of RootRef
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbKvtFns

  CoreDbCtxRef* = ref object of RootRef
    ## Context for `CoreDbMptRef` and `CoreDbAccRef`
    parent*: CoreDbRef
    methods*: CoreDbCtxFns

  CoreDbMptRef* = ref object of RootRef
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent*: CoreDbRef
    methods*: CoreDbMptFns

  CoreDbAccRef* = ref object of RootRef
    ## Similar to `CoreDbKvtRef`, only dealing with `CoreDbAccount` data
    ## rather than `Blob` values.
    parent*: CoreDbRef
    methods*: CoreDbAccFns

  CoreDbColRef* = ref object of RootRef
    ## Generic state root: `Hash256` for legacy, `VertexID` for Aristo. This
    ## object makes only sense in the context of an *MPT*.
    parent*: CoreDbRef
    ready*: bool              ## Must be set `true` to enable

  CoreDbTxRef* = ref object of RootRef
    ## Transaction descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbTxFns

  CoreDbCaptRef* = ref object
    ## Db transaction tracer derived from `CoreDbRef`
    parent*: CoreDbRef
    methods*: CoreDbCaptFns

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
