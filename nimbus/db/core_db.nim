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
  chronicles,
  eth/[common, trie/db],
  ./core_db/[base, core_apps, legacy]

export
  common,
  core_apps,

  # Not all symbols from the object sources will be exported by default
  CoreDbCaptFlags,
  CoreDbCaptRef,
  CoreDbKvtRef,
  CoreDbMptRef,
  CoreDbPhkRef,
  CoreDbRef,
  CoreDbTxID,
  CoreDbTxRef,
  CoreDbType,
  LegacyCoreDbRef, # for shortTimeReadOnly()
  beginTransaction,
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
  newCoreDbCaptRef,
  parent,
  phk,
  phkPrune,
  put,
  recorder,
  rollback,
  rootHash,
  safeDispose,
  setTransactionID

logScope:
  topics = "core_db"

# ------------------------------------------------------------------------------
# Private functions: helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "ChainDB " & info

proc itNotImplemented(db: CoreDbRef, name: string) {.used.} =
  debug logTxt "iterator not implemented", dbType=db.dbType, meth=name

proc tmplNotImplemented*(db: CoreDbRef, name: string) {.used.} =
  debug logTxt "template not implemented", dbType=db.dbType, meth=name

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
  db.newLegacyCoreDbRef()

proc newCoreDbRef*(
    dbType: static[CoreDbType];
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == LegacyDbMemory:
    newLegacyMemoryCoreDbRef()
  else:
    {.error: "Unsupported dbType for CoreDbRef.init()".}

proc newCoreDbRef*(
    dbType: static[CoreDbType];
    path: string;
      ): CoreDbRef =
  ## General constructor (the `path` argument is ignored for volatile/memory
  ## type DB)
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == LegacyDbMemory:
    newLegacyMemoryCoreDbRef()
  elif dbType == LegacyDbPersistent:
    newLegacyPersistentCoreDbRef path
  else:
    {.error: "Unsupported dbType for CoreDbRef.init()".}

# ------------------------------------------------------------------------------
# Public template wrappers
# ------------------------------------------------------------------------------

template shortTimeReadOnly*(db: CoreDbRef; id: CoreDbTxID; body: untyped) =
  proc action() {.gcsafe, raises: [CatchableError].} =
    body
  case db.dbType:
  of LegacyDbMemory, LegacyDbPersistent:
    db.LegacyCoreDbRef.shortTimeReadOnly(id, action)
  else:
    db.tmplNotImplemented "shortTimeReadOnly"

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator pairs*(
    db: CoreDbCaptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  case db.parent.dbType:
  of LegacyDbMemory, LegacyDbPersistent:
    for k,v in db.LegacyCoreDbCaptRef:
      yield (k,v)
  else:
    db.parent.itNotImplemented "pairs/capt"

iterator pairs*(
    db: CoreDbMptRef;
      ): (Blob, Blob)
      {.gcsafe, raises: [RlpError].} =
  case db.parent.dbType:
  of LegacyDbMemory, LegacyDbPersistent:
    for k,v in db.LegacyCoreDbMptRef:
      yield (k,v)
  else:
    db.parent.itNotImplemented "pairs/mpt"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
