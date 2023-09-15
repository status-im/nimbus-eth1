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
  eth/[common, trie/nibbles],
  results,
  "."/[aristo_desc, aristo_hike]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchPayloadImpl(
    rc: Result[Hike,(Hike,AristoError)];
      ): Result[PayloadRef,(VertexID,AristoError)] =
  if rc.isErr:
    let vid =
      if rc.error[0].legs.len == 0: VertexID(0)
      else: rc.error[0].legs[^1].wp.vid
    return err((vid, rc.error[1]))
  ok rc.value.legs[^1].wp.vtx.lData

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
  key.hikeUp(db).fetchPayloadImpl

proc fetchPayload*(
    db: AristoDbRef;
    root: VertexID;
    path: Blob;
      ): Result[PayloadRef,(VertexID,AristoError)] =
  ## Variant of `fetchPayload()`
  ##
  path.initNibbleRange.hikeUp(root, db).fetchPayloadImpl

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
