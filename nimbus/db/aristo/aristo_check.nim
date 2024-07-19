# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Consistency checks
## ===============================
##
{.push raises: [].}

import
  std/[algorithm, sequtils, tables],
  eth/common,
  stew/interval_set,
  results,
  ./aristo_walk/persistent,
  "."/[aristo_desc, aristo_get, aristo_init],
  ./aristo_check/[check_be, check_top]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTop*(
    db: AristoDbRef, # Database, top layer
    proofMode = false, # Has proof nodes
): Result[void, (VertexID, AristoError)] =
  ## Verify that the cache structure is correct as it would be after `merge()`
  ## operations. Unless `proofMode` is set `true` it would not fully check
  ## against the backend, which is typically not applicable after `delete()`
  ## operations.
  ##
  ## The following is verified:
  ##
  ## * Each `sTab[]` entry has a valid vertex which can be compiled as a node.
  ##   If `proofMode` is set `false`, the Merkle hashes are recompiled and must
  ##   match.
  ##
  if proofMode:
    ?db.checkTopProofMode()
  else:
    ?db.checkTopStrict()

  db.checkTopCommon()

proc checkBE*(
    db: AristoDbRef, # Database, top layer
): Result[void, (VertexID, AristoError)] =
  ## Verify database backend structure. If the argument `relax` is set `false`,
  ## all necessary Merkle hashes are compiled and verified. If the argument
  ## `cache` is set `true`, the cache is also checked so that a safe operation
  ## (like `resolveBackendFilter()`) will leave the backend consistent.
  ##
  ## The following is verified:
  ##
  ## * Each vertex ID on the structural table can be represented as a Merkle
  ##   patricia Tree node. If `relax` is set `false`, the Merkle hashes are
  ##   all recompiled and must match.
  ##
  ## * The set of free vertex IDa as potentally suppliedby the ID generator
  ##   state is disjunct to the set of already used vertex IDs on the database.
  ##   Moreover, the union of both sets is equivalent to the set of positive
  ##   `uint64` numbers.
  ##
  case db.backend.kind
  of BackendMemory:
    return MemBackendRef.checkBE db
  of BackendRocksDB, BackendRdbHosting:
    return RdbBackendRef.checkBE db
  of BackendVoid:
    return VoidBackendRef.checkBE db

proc check*(
    db: AristoDbRef, # Database, top layer
    relax = false, # Check existing hashes only
    cache = true, # Also verify against top layer cache
    proofMode = false, # Has proof nodes
): Result[void, (VertexID, AristoError)] =
  ## Shortcut for running `checkTop()` followed by `checkBE()`
  ?db.checkTop(proofMode = proofMode)
  ?db.checkBE()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
