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
  ../aristo,
  ./backend/legacy_db,
  ./base,
  #./core_apps_legacy as core_apps
  ./core_apps_newapi as core_apps

export
  common,
  core_apps,

  # Provide a standard interface for calculating merkle hash signatures,
  # here by quoting `Aristo` functions.
  VerifyAristoForMerkleRootCalc,
  MerkleSignRef,
  merkleSignBegin,
  merkleSignAdd,
  merkleSignCommit,
  to,

  # Not all symbols from the object sources will be exported by default
  CoreDbAccount,
  CoreDbApiError,
  CoreDbErrorCode,
  CoreDbErrorRef,
  CoreDbRef,
  CoreDbType,
  CoreDbVidRef,
  CoreDxAccRef,
  CoreDxCaptRef,
  CoreDxKvtRef,
  CoreDxMptRef,
  CoreDxPhkRef,
  CoreDxTxID,
  CoreDxTxRef,
  `$$`,
  backend,
  beginTransaction,
  commit,
  compensateLegacySetup,
  del,
  delete,
  dispose,
  fetch,
  fetchOrEmpty,
  finish,
  get,
  getOrEmpty,
  getRoot,
  getTransactionID,
  hash,
  hasKey,
  hashOrEmpty,
  hasPath,
  isLegacy,
  isPruning,
  logDb,
  merge,
  newAccMpt,
  newCapture,
  newKvt,
  newMpt,
  newTransaction,
  pairs,
  parent,
  put,
  recast,
  recorder,
  replicate,
  rollback,
  rootVid,
  safeDispose,
  setTransactionID,
  toLegacy,
  toMpt,
  toPhk,
  toTransactionID

when ProvideCoreDbLegacyAPI:
  type
    CoreDyTxID = CoreDxTxID|CoreDbTxID
  export
    CoreDbCaptFlags,
    CoreDbCaptRef,
    CoreDbKvtRef,
    CoreDbMptRef,
    CoreDbPhkRef,
    CoreDbTxID,
    CoreDbTxRef,
    capture,
    contains,
    kvt,
    mptPrune,
    phkPrune,
    rootHash
else:
  type
    CoreDyTxID = CoreDxTxID

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

  else:
    {.error: "Unsupported dbType for memory-only newCoreDbRef()".}

# ------------------------------------------------------------------------------
# Public template wrappers
# ------------------------------------------------------------------------------

template shortTimeReadOnly*(id: CoreDyTxID; body: untyped) =
  proc action() =
    body
  id.shortTimeReadOnly action

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
