# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Obects Retrival Via Traversal Path
## ===============================================
##
{.push raises: [].}

import
  eth/common,
  results,
  "."/[aristo_desc, aristo_hike]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchPayload*(
    db: AristoDbRef;
    key: LeafTie;
      ): Result[PayloadRef,(VertexID,AristoError)] =
  ## Cascaded attempt to traverse the `Aristo Trie` and fetch the value of a
  ## leaf vertex. This function is complementary to `merge()`.
  ##
  let hike = key.hikeUp db
  if hike.error != AristoError(0):
    let vid =
      if hike.legs.len == 0: VertexID(0)
      else: hike.legs[^1].wp.vid
    return err((vid,hike.error))
  ok hike.legs[^1].wp.vtx.lData

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
