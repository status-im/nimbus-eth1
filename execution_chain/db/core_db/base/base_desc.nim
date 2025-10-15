# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ../../[aristo, kvt]

type
  CoreDbType* = enum
    Ooops
    AristoDbMemory            ## Memory backend emulator
    AristoDbRocks             ## RocksDB backend

const
  CoreDbPersistentTypes* = {AristoDbRocks}
    ## List of persistent DB types (currently only a single one)

type
  CoreDbRc*[T] = Result[T,CoreDbError]

  CoreDbAccount* = AristoAccount
    ## Generic account record representation. The data fields
    ## look like:
    ##   * nonce*:    AccountNonce  -- Some `uint64` type
    ##   * balance*:  UInt256       -- Account balance
    ##   * codeHash*: Hash32        -- Lookup value

  CoreDbErrorCode* = enum
    Unset = 0
    Unspecified

    AccNotFound
    ColUnacceptable
    HashNotAvailable
    KvtNotFound
    MptNotFound
    ProofCreate
    ProofVerify
    RlpException
    StoNotFound
    TxPending

  CoreDbKvtType* = KvtCFs

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object
    ## Database descriptor
    dbType*: CoreDbType            ## Type of database backend
    mpt*: AristoDbRef              ## `Aristo` database
    kvts*: array[CoreDbKvtType, KvtDbRef] ## `KVT` key-value tables

  CoreDbTxRef* = ref object
    ## Transaction descriptor
    aTx*: AristoTxRef              ## `Aristo` transaction (if any)
    kTxs*: array[CoreDbKvtType, KvtTxRef] ## `KVT` transactions (if any)

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
