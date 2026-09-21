# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common/[base, hashes],
  results,
  ../[aristo, kvt]

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
    KvtNotFound
    ProofCreate
    ProofVerify
    StoNotFound

  # --------------------------------------------------
  # Production descriptors
  # --------------------------------------------------
  CoreDbRef* = ref object
    ## Database descriptor
    mpt*: AristoDbRef           ## `Aristo` database
    kvt*: KvtDbRef              ## `KVT` key-value table

  BlockHashFn* =
    proc(n: BlockNumber): Opt[Hash32] {.gcsafe, raises: [].}
    ## Resolves a block number to the block hash on *this* frame's branch.
    ## `ForkedChain` installs one on every block frame so that `BLOCKHASH` and
    ## friends see the branch being executed rather than the canonical chain;
    ## `Opt.none` means "not on this branch", ie fall back to the database,
    ## which is canonical below the base block.

  CoreDbTxRef* = ref object
    ## Transaction descriptor
    aTx*: AristoTxRef           ## `Aristo` transaction (if any)
    kTx*: KvtTxRef              ## Pending `KVT` write set
    blockHashFn*: BlockHashFn   ## Branch-local number -> hash, may be nil

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
