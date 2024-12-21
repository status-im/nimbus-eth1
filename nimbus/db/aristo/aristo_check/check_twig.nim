# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ".."/[aristo_compute, aristo_desc, aristo_fetch, aristo_part]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTwig*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;             # Data path
      ): Result[void,AristoError] =
  let
    proof = ? db.partAccountTwig(accPath)
    key = ? db.computeKey (VertexID(1),VertexID(1))
  discard ? proof[0].partUntwigPath(key.to(Hash32), accPath)

  ok()

proc checkTwig*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;                  # Account key
    stoPath: Hash32;                  # Storage key
      ): Result[void,AristoError] =
  let
    proof = ? db.partStorageTwig(accPath, stoPath)
    vid = ? db.fetchStorageID accPath
    key = ? db.computeKey (VertexID(1),vid)
  discard ? proof[0].partUntwigPath(key.to(Hash32), stoPath)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

