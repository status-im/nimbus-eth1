# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  std/[algorithm, sequtils, sets, tables],
  eth/common,
  stew/[interval_set, results],
  ./aristo_walk/persistent,
  "."/[aristo_desc, aristo_get, aristo_init, aristo_vid, aristo_utils],
  ./aristo_check/[check_be, check_cache]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkCache*(
    db: AristoDbRef;                   # Database, top layer
    relax = false;                     # Check existing hashes only
      ): Result[void,(VertexID,AristoError)] =
  ## Verify that the cache structure is correct as it would be after `merge()`
  ## and `hashify()` operations. Unless `relaxed` is set `true` it would not
  ## fully check against the backend, which is typically not applicable after
  ## `delete()` operations.
  ##
  ## The following is verified:
  ##
  ## * Each `sTab[]` entry has a valid vertex which can be compiled as a node.
  ##   If `relax` is set `false`, the Merkle hashes are recompiled and must
  ##   match.
  ##
  ## * The hash table `kMap[]` and its inverse lookup table `pAmk[]` must
  ##   correnspond.
  ##
  if relax:
    let rc = db.checkCacheRelaxed()
    if rc.isErr:
      return rc
  else:
    let rc = db.checkCacheStrict()
    if rc.isErr:
      return rc

  db.checkCacheCommon()


proc checkBE*(
    db: AristoDbRef;                   # Database, top layer
    relax = true;                      # Not re-compiling hashes if `true`
    cache = true;                      # Also verify cache
      ): Result[void,(VertexID,AristoError)] =
  ## Veryfy database backend structure. If the argument `relax` is set `false`,
  ## all necessary Merkle hashes are compiled and verified. If the argument
  ## `cache` is set `true`, the cache is also checked so that a `safe()`
  ## operation will leave the backend consistent.
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
  if not db.backend.isNil:
    let be = db.to(TypedBackendRef)
    case be.kind:
    of BackendMemory:
      return MemBackendRef.checkBE(db, cache=cache, relax=relax)
    of BackendRocksDB:
      return RdbBackendRef.checkBE(db, cache=cache, relax=relax)
    of BackendNone:
      return NoneBackendRef.checkBE(db, cache=cache, relax=relax)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
