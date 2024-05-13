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
  #./core_apps_legacy as core_apps -- avoid
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
  isAristo,
  toAristo,
  toAristoProfData,
  toAristoOldestState,

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
    chainId: ChainId;
      ): CoreDbRef
      {.gcsafe, deprecated: "use newCoreDbRef(LegacyDbPersistent,<path>)".} =
  ## Legacy constructor.
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  let res = db.newLegacyPersistentCoreDbRef()
  res.chainId = chainId
  res

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    chainId: ChainId;
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == LegacyDbMemory:
    let res = newLegacyMemoryCoreDbRef()

  elif dbType == AristoDbMemory:
    let res = newAristoMemoryCoreDbRef()

  elif dbType == AristoDbVoid:
    let res = newAristoVoidCoreDbRef()

  else:
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()".}

  res.chainId = chainId
  res

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    chainId: ChainId;
    qidLayout: QidLayoutRef;         # `Aristo` only
      ): CoreDbRef =
  ## Constructor for volatile/memory type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  ##
  when dbType == AristoDbMemory:
    let res = newAristoMemoryCoreDbRef(DefaultQidLayoutRef)

  elif dbType == AristoDbVoid:
    let res = newAristoVoidCoreDbRef()

  else:
    {.error: "Unsupported constructor " & $dbType & ".newCoreDbRef()" &
             " with qidLayout argument".}

  res.chainId = chainId
  res

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
