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
  "../.."/[aristo, aristo/aristo_profile, kvt],
  ./base_config

type
  CoreDbType* = enum
    Ooops
    AristoDbMemory            ## Memory backend emulator
    AristoDbRocks             ## RocksDB backend
    AristoDbVoid              ## No backend

const
  CoreDbPersistentTypes* = {AristoDbRocks}
    ## List of persistent DB types (currently only a single one)

  CoreDbVidGeneric* = VertexID(2)
    ## Generic `MPT` root vertex ID for calculating Merkle hashes

type
  CoreDbProfListRef* = AristoDbProfListRef
    ## Borrowed from `aristo_profile`, only used in profiling mode

  CoreDbProfData* = AristoDbProfData
    ## Borrowed from `aristo_profile`, only used in profiling mode

  CoreDbRc*[T] = Result[T,CoreDbError]

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

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object
    ## Database descriptor
    dbType*: CoreDbType           ## Type of database backend
    defCtx*: CoreDbCtxRef         ## Default context

    # Optional api interface (can be re-directed/intercepted)
    ariApi*: AristoApiRef         ## `Aristo` api
    kvtApi*: KvtApiRef            ## `KVT` api

    # Optional profiling and debugging stuff
    when CoreDbEnableApiTracking:
      trackLedgerApi*: bool       ## Debugging, suggestion for ledger
      trackCoreDbApi*: bool       ## Debugging, support
    when CoreDbEnableApiJumpTable:
      profTab*: CoreDbProfListRef ## Profiling data (if any)
      ledgerHook*: RootRef        ## Debugging/profiling, to be used by ledger
      tracerHook*: RootRef        ## Debugging/tracing

  CoreDbCtxRef* = ref object
    ## Shared context for `CoreDbMptRef`, `CoreDbAccRef`, `CoreDbKvtRef`
    parent*: CoreDbRef
    mpt*: AristoDbRef           ## `Aristo` database
    kvt*: KvtDbRef              ## `KVT` key-value table

  CoreDbKvtRef* = distinct CoreDbCtxRef
    ## Statically initialised Key-Value pair table

  CoreDbAccRef* = distinct CoreDbCtxRef
    ## Similar to `CoreDbKvtRef`, only dealing with `Aristo` accounts

  CoreDbMptRef* = distinct CoreDbCtxRef
    ## Generic MPT

  CoreDbTxRef* = ref object
    ## Transaction descriptor
    ctx*: CoreDbCtxRef          ## Context (also contains `Aristo` descriptor)
    aTx*: AristoTxRef           ## `Aristo` transaction (if any)
    kTx*: KvtTxRef              ## `KVT` transaction (if any)

  CoreDbError* = object
    ## Generic error object
    error*: CoreDbErrorCode
    ctx*: string     ## Context where the exception or error occured
    case isAristo*: bool
    of true:
      aErr*: AristoError
    else:
      kErr*: KvtError

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
