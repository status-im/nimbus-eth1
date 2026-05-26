# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common/hashes,
  results,
  ../[aristo_desc, aristo_fetch, aristo_proof]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTwig*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;             # Data path
      ): Result[void,AristoError] =
  let
    proof = ? db.makeAccountProof(accPath)
    key = ? db.fetchStateRoot()
  discard ? proof[0].verifyProof(key, accPath)

  ok()

proc checkTwig*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;                  # Account key
    stoPath: Hash32;                  # Storage key
      ): Result[void,AristoError] =
  let
    proof = ? db.makeStorageProof(accPath, stoPath)
    key = ? db.fetchStorageRoot accPath
  discard ? proof[0].verifyProof(key, stoPath)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

