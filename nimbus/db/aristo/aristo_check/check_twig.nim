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
  eth/common,
  results,
  ".."/[aristo_compute, aristo_desc, aristo_fetch, aristo_part]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTwig*(
    db: AristoDbRef;                   # Database
    root: VertexID;                    # Start node
    path: openArray[byte];             # Data path
      ): Result[void,AristoError] =
  let
    proof = ? db.partGenericTwig(root, path)
    key = ? db.computeKey (root,root)
    pyl = ? proof[0].partUntwigGeneric(key.to(Hash32), path)

  ok()

proc checkTwig*(
    db: AristoDbRef;                   # Database
    accPath: Hash32;                  # Account key
    stoPath: Hash32;                  # Storage key
      ): Result[void,AristoError] =
  let
    proof = ? db.partStorageTwig(accPath, stoPath)
    vid = ? db.fetchStorageID accPath
    key = ? db.computeKey (VertexID(1),vid)
    pyl = ? proof[0].partUntwigPath(key.to(Hash32), stoPath)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

