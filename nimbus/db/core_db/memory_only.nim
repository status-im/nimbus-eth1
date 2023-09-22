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
  std/options,
  eth/[common, trie/db],
  "."/[base, core_apps, legacy_db]

export
  common,
  core_apps,

  # Not all symbols from the object sources will be exported by default
  CoreDbCaptFlags,
  CoreDbError,
  CoreDbCaptRef,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbPhkRef,
  CoreDbRef,
  CoreDbTxID,
  CoreDbTxRef,
  CoreDbType,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxID,
  CoreDxTxRef,
  backend,
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
  isLegacy,
  isPruning,
  kvt,
  maybeGet,
  mptPrune,
  newCapture,
  newMpt,
  newMptPrune,
  newPhk,
  newPhkPrune,
  newTransaction,
  pairs,
  parent,
  phkPrune,
  put,
  recorder,
  replicate,
  rollback,
  rootHash,
  safeDispose,
  setTransactionID,
  toLegacy,
  toMpt,
  toPhk,
  toTransactionID

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
  ##
  db.newLegacyPersistentCoreDbRef()

proc newCoreDbRef*(dbType: static[CoreDbType]): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == LegacyDbMemory:
    newLegacyMemoryCoreDbRef()

  else:
    {.error: "Unsupported dbType for memory newCoreDbRef()".}

# ------------------------------------------------------------------------------
# Public template wrappers
# ------------------------------------------------------------------------------

template shortTimeReadOnly*(id: CoreDxTxID|CoreDbTxID; body: untyped) =
  proc action() =
    body
  id.shortTimeReadOnly action

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
