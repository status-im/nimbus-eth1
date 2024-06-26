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
    codeHash*: Hash256

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
    CtGeneric = 2 # columns smaller than 2 are not provided
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
  CoreDbKvtLenFn* = proc(k: openArray[byte]): CoreDbRc[int] {.noRaise.}
  CoreDbKvtDelFn* = proc(k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtPutFn* =
    proc(k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbKvtForgetFn* = proc(): CoreDbRc[void] {.noRaise.}
  CoreDbKvtHasKeyFn* = proc(k: openArray[byte]): CoreDbRc[bool] {.noRaise.}

  CoreDbKvtFns* = object
    ## Methods for key-value table
    backendFn*:     CoreDbKvtBackendFn
    getFn*:         CoreDbKvtGetFn
    lenFn*:         CoreDbKvtLenFn
    delFn*:         CoreDbKvtDelFn
    putFn*:         CoreDbKvtPutFn
    hasKeyFn*:      CoreDbKvtHasKeyFn
    forgetFn*:      CoreDbKvtForgetFn

  # --------------------------------------------------
  # Sub-descriptor: MPT context methods
  # --------------------------------------------------
  CoreDbCtxGetColumnFn* = proc(
    cCtx: CoreDbCtxRef; colType: CoreDbColType; clearData: bool): CoreDbMptRef {.noRaise.}
  CoreDbCtxGetAccountsFn* = proc(cCtx: CoreDbCtxRef): CoreDbAccRef {.noRaise.}
  CoreDbCtxForgetFn* = proc(cCtx: CoreDbCtxRef) {.noRaise.}

  CoreDbCtxFns* = object
    ## Methods for context maniulation
    getColumnFn*:   CoreDbCtxGetColumnFn
    getAccountsFn*: CoreDbCtxGetAccountsFn
    forgetFn*:      CoreDbCtxForgetFn

  # --------------------------------------------------
  # Sub-descriptor: generic Mpt methods
  # --------------------------------------------------
  CoreDbMptBackendFn* = proc(cMpt: CoreDbMptRef): CoreDbMptBackendRef {.noRaise.}
  CoreDbMptFetchFn* =
    proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbMptFetchAccountFn* =
    proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbMptDeleteFn* =
    proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbMptMergeFn* =
    proc(cMpt: CoreDbMptRef, k: openArray[byte]; v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbMptHasPathFn* = proc(cMpt: CoreDbMptRef, k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbMptStateFn* = proc(cMpt: CoreDbMptRef, updateOk: bool): CoreDbRc[Hash256] {.noRaise.}

  CoreDbMptFns* = object
    ## Methods for trie objects
    backendFn*:   CoreDbMptBackendFn
    fetchFn*:     CoreDbMptFetchFn
    deleteFn*:    CoreDbMptDeleteFn
    mergeFn*:     CoreDbMptMergeFn
    hasPathFn*:   CoreDbMptHasPathFn
    stateFn*:     CoreDbMptStateFn


  # ----------------------------------------------------
  # Sub-descriptor: Account column methods
  # ------------------------------------------------------
  CoreDbAccBackendFn* = proc(cAcc: CoreDbAccRef): CoreDbAccBackendRef {.noRaise.}
  CoreDbAccFetchFn* = proc(cAcc: CoreDbAccRef, k: EthAddress): CoreDbRc[CoreDbAccount] {.noRaise.}
  CoreDbAccDeleteFn* = proc(cAcc: CoreDbAccRef, k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccClearStorageFn* = proc(cAcc: CoreDbAccRef,k: EthAddress): CoreDbRc[void] {.noRaise.}
  CoreDbAccMergeFn* = proc(cAcc: CoreDbAccRef, v: CoreDbAccount): CoreDbRc[void] {.noRaise.}
  CoreDbAccHasPathFn* = proc(cAcc: CoreDbAccRef, k: EthAddress): CoreDbRc[bool] {.noRaise.}
  CoreDbAccStateFn* = proc(cAcc: CoreDbAccRef, updateOk: bool): CoreDbRc[Hash256] {.noRaise.}

  CoreDbSlotFetchFn* =
    proc(cAcc: CoreDbAccRef, a: EthAddress; k: openArray[byte]): CoreDbRc[Blob] {.noRaise.}
  CoreDbSlotDeleteFn* =
    proc(cAcc: CoreDbAccRef,a: EthAddress; k: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbSlotHasPathFn* =
    proc(cAcc: CoreDbAccRef, a: EthAddress; k: openArray[byte]): CoreDbRc[bool] {.noRaise.}
  CoreDbSlotMergeFn* =
    proc(cAcc: CoreDbAccRef, a: EthAddress; k, v: openArray[byte]): CoreDbRc[void] {.noRaise.}
  CoreDbSlotStateFn* =
    proc(cAcc: CoreDbAccRef, a: EthAddress; updateOk: bool): CoreDbRc[Hash256] {.noRaise.}
  CoreDbSlotStateEmptyFn* =
    proc(cAcc: CoreDbAccRef, a: EthAddress): CoreDbRc[bool] {.noRaise.}

  CoreDbAccFns* = object
    ## Methods for trie objects
    backendFn*:      CoreDbAccBackendFn
    fetchFn*:        CoreDbAccFetchFn
    clearStorageFn*: CoreDbAccClearStorageFn
    deleteFn*:       CoreDbAccDeleteFn
    hasPathFn*:      CoreDbAccHasPathFn
    mergeFn*:        CoreDbAccMergeFn
    stateFn*:        CoreDbAccStateFn

    slotFetchFn*:      CoreDbSlotFetchFn
    slotDeleteFn*:     CoreDbSlotDeleteFn
    slotHasPathFn*:    CoreDbSlotHasPathFn
    slotMergeFn*:      CoreDbSlotMergeFn
    slotStateFn*:      CoreDbSlotStateFn
    slotStateEmptyFn*: CoreDbSlotStateEmptyFn

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
