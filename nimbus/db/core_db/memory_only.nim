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
  std/options,
  eth/[common, trie/db],
  ../aristo,
  ./backend/[aristo_db, legacy_db]

import
  #./core_apps_legacy as core_apps
  ./core_apps_newapi as core_apps
import
  ./base except bless
import
  ./base_iterators

export
  base,
  base_iterators,
  common,
  core_apps,

  # see `aristo_db`
  toAristo,

  # see `legacy_db`
  isLegacy,
  toLegacy,

  # Standard interface for calculating merkle hash signatures (see `aristo`)
  MerkleSignRef,
  merkleSignBegin,
  merkleSignAdd,
  merkleSignCommit,
  to

# ------------------------------------------------------------------------------
# Public constructors
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
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()".}

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

  elif dbType == AristoDbVoid:
    newAristoVoidCoreDbRef()

  else:
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()" &
             " with qidLayout argument".}

# ------------------------------------------------------------------------------
# Public template wrappers
# ------------------------------------------------------------------------------

template shortTimeReadOnly*(id: CoreDbTxID; body: untyped) =
  proc action() =
    body
  id.shortTimeReadOnly action

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
