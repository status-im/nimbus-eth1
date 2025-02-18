# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  eth/common/hashes,
  results,
  ./aristo_walk/persistent,
  ./aristo_desc,
  ./aristo_check/[check_top, check_twig]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTop*(
    db: AristoTxRef;                   # Database, top layer
    proofMode = false;                 # Has proof nodes
      ): Result[void,(VertexID,AristoError)] =
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
    ? db.checkTopProofMode()
  else:
    ? db.checkTopStrict()

  db.checkTopCommon()

proc check*(
    db: AristoTxRef;                   # Database
    relax = false;                     # Check existing hashes only
    cache = true;                      # Also verify against top layer cache
    proofMode = false;                 # Has proof nodes
      ): Result[void,(VertexID,AristoError)] =
  ## Shortcut for running `checkTop()` followed by `checkBE()`
  ? db.checkTop(proofMode = proofMode)
  # ? db.checkBE()
  ok()

proc check*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;                   # Account key
      ): Result[void,AristoError] =
  ## Check accounts tree path `accPath` against portal proof generation and
  ## verification.
  ##
  ## Note that this check might have side effects in that it might compile
  ## the hash keys on the accounts sub-tree.
  db.checkTwig(accPath)

proc check*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;                   # Account key
    stoPath: Hash32;                   # Storage key
      ): Result[void,AristoError] =
  ## Check account tree `Account key` against portal proof generation and
  ## verification.
  ##
  ## Note that this check might have side effects in that it might compile
  ## the hash keys on the particulat storage sub-tree.
  db.checkTwig(accPath, stoPath)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
