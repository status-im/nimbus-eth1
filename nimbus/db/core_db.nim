# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Core database replacement wrapper object
## ========================================
##
## See `core_db/README.md`
##
{.push raises: [].}

import
  eth/[common, trie/db],
  ./core_db/[base, core_apps, legacy]

export
  common,
  core_apps,

  # Not all symbols from the object sources will be exported by default
  CoreDbCaptFlags,
  CoreDbCaptRef,
  CoreDbKvtObj,
  CoreDbMptRef,
  CoreDbPhkRef,
  CoreDbRef,
  CoreDbTxID,
  CoreDbTxRef,
  CoreDbType,
  beginTransaction,
  capture,
  commit,
  compensateLegacySetup,
  contains,
  dbType,
  del,
  dispose,
  get,
  getTransactionID,
  isPruning,
  kvt,
  maybeGet,
  mpt,
  mptPrune,
  pairs,
  parent,
  phk,
  phkPrune,
  put,
  recorder,
  replicate,
  rollback,
  rootHash,
  safeDispose,
  setTransactionID,
  toMpt,
  toPhk

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newCoreDbRef*(
    db: TrieDatabaseRef;
      ): CoreDbRef
      {.gcsafe, deprecated: "use newCoreDbRef(LegacyDbPersistent,<path>)".} =
  ## Legacy constructor.
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  db.newLegacyPersistentCoreDbRef()

proc newCoreDbRef*(dbType: static[CoreDbType]): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == LegacyDbMemory:
    newLegacyMemoryCoreDbRef()
  else:
    {.error: "Unsupported dbType for memory newCoreDbRef()".}

proc newCoreDbRef*(dbType: static[CoreDbType]; path: string): CoreDbRef =
  ## Constructor for persistent type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == LegacyDbPersistent:
    newLegacyPersistentCoreDbRef path
  else:
    {.error: "Unsupported dbType for persistent newCoreDbRef()".}

# ------------------------------------------------------------------------------
# Public template wrappers
# ------------------------------------------------------------------------------

template shortTimeReadOnly*(id: CoreDbTxID; body: untyped) =
  proc action() {.gcsafe, raises: [CatchableError].} =
    body
  id.shortTimeReadOnly action

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
