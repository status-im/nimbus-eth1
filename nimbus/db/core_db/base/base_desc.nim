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
  results,
  ../../aristo,
  ../../kvt,
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

  CoreDbAccount* = AristoAccount
    ## Generic account record representation. The data fields
    ## look like:
    ##   * nonce*:    AccountNonce  -- Some `uint64` type
    ##   * balance*:  UInt256       -- Account balance
    ##   * codeHash*: Hash256       -- Lookup value

  CoreDbErrorCode* = enum
    Unset = 0
    Unspecified

    AccNotFound
    ColUnacceptable
    HashNotAvailable
    KvtNotFound
    MptNotFound
    RlpException
    StoNotFound
    TxPending

  CoreDbColType* = enum
    CtGeneric = 2 # columns smaller than 2 are not provided

  CoreDbCaptFlags* {.pure.} = enum
    PersistPut
    PersistDel

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object of RootRef
    ## Database descriptor
    dbType*: CoreDbType         ## Type of database backend
    trackNewApi*: bool          ## Debugging, support
    trackLedgerApi*: bool       ## Debugging, suggestion for subsequent ledger
    profTab*: CoreDbProfListRef ## Profiling data (if any)
    ledgerHook*: RootRef        ## Debugging/profiling, to be used by ledger
    kdbBase*: CoreDbKvtBaseRef  ## Kvt subsystem
    adbBase*: CoreDbAriBaseRef  ## Aristo subsystem
    ctx*: CoreDbCtxRef          ## Currently active context

  CoreDbKvtBaseRef* = ref object of RootRef
    parent*: CoreDbRef
    api*: KvtApiRef             ## Api functions can be re-directed
    kdb*: KvtDbRef              ## Shared key-value table
    cache*: CoreDbKvtRef        ## Shared transaction table wrapper

  CoreDbAriBaseRef* = ref object of RootRef
    parent*: CoreDbRef
    api*: AristoApiRef          ## Api functions can be re-directed

  CoreDbErrorRef* = ref object of RootRef
    ## Generic error object
    error*: CoreDbErrorCode
    parent*: CoreDbRef
    ctx*: string     ## Context where the exception or error occured
    case isAristo*: bool
    of true:
      aErr*: AristoError
    else:
      kErr*: KvtError

  CoreDbKvtRef* = ref object of RootRef
    ## Statically initialised Key-Value pair table living in `CoreDbRef`
    parent*: CoreDbRef
    kvt*: KvtDbRef              ## In most cases different from `base.kdb`

  CoreDbCtxRef* = ref object of RootRef
    ## Context for `CoreDbMptRef` and `CoreDbAccRef`
    parent*: CoreDbRef
    mpt*: AristoDbRef           ## Aristo MPT database

  CoreDbMptRef* = ref object of RootRef
    ## Hexary/Merkle-Patricia tree derived from `CoreDbRef`, will be
    ## initialised on-the-fly.
    parent*: CoreDbRef
    rootID*: VertexID           ## State root, may be zero unless account

  CoreDbAccRef* = ref object of RootRef
    ## Similar to `CoreDbKvtRef`, only dealing with `CoreDbAccount` data
    ## rather than `Blob` values.
    parent*: CoreDbRef

  CoreDbTxRef* = ref object of RootRef
    ## Transaction descriptor derived from `CoreDbRef`
    parent*: CoreDbRef
    aTx*: AristoTxRef
    kTx*: KvtTxRef

when false: # TODO
  type
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

    CoreDbCaptRef* = ref object
      ## Db transaction tracer derived from `CoreDbRef`
      parent*: CoreDbRef
      methods*: CoreDbCaptFns

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
