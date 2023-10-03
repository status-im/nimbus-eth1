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
  ./backend/[aristo_db, legacy_db],
  "."/[base, core_apps]

export
  common,
  core_apps,

  # Not all symbols from the object sources will be exported by default
  CoreDbAccount,
  CoreDbApiError,
  CoreDbCaptFlags,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbCaptRef,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbPhkRef,
  CoreDbRef,
  CoreDbTxID,
  CoreDbTxRef,
  CoreDbType,
  CoreDbVidRef,
  CoreDxAccRef,
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
  delete,
  dispose,
  fetch,
  finish,
  get,
  getRoot,
  getTransactionID,
  hash,
  isLegacy,
  isPruning,
  kvt,
  merge,
  mptPrune,
  newAccMpt,
  newCapture,
  newMpt,
  newTransaction,
  pairs,
  parent,
  phkPrune,
  put,
  recast,
  recorder,
  replicate,
  rollback,
  rootHash,
  rootVid,
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

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == LegacyDbMemory:
    newLegacyMemoryCoreDbRef()

  elif dbType == AristoDbMemory:
    newAristoMemoryCoreDbRef()

  elif dbType == AristoDbVoid:
    newAristoVoidCoreDbRef()

  else:
    {.error: "Unsupported dbType for memory-only newCoreDbRef()".}

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    qidLayout: QidLayoutRef;         # `Aristo` only
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == AristoDbMemory:
    newAristoMemoryCoreDbRef(DefaultQidLayoutRef)

  else:
    {.error: "Unsupported dbType for newCoreDbRef() with qidLayout argument".}

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
