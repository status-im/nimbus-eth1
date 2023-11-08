# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  eth/trie/nibbles,
  results,
  "."/[aristo_desc, aristo_hike]

const
  AcceptableHikeStops = {
    HikeBranchTailEmpty,
    HikeBranchBlindEdge,
    HikeExtTailEmpty,
    HikeExtTailMismatch}

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
    if rc.error[1] in  AcceptableHikeStops:
      return err((vid, FetchPathNotFound))
    return err((vid, rc.error[1]))
  ok rc.value.legs[^1].wp.vtx.lData

proc fetchPayloadImpl(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[PayloadRef,(VertexID,AristoError)] =
  path.initNibbleRange.hikeUp(root, db).fetchPayloadImpl

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
    path: openArray[byte];
      ): Result[PayloadRef,(VertexID,AristoError)] =
  ## Variant of `fetchPayload()`
  ##
  if path.len == 0:
    return err((VertexID(0),LeafKeyInvalid))
  db.fetchPayloadImpl(root, path)

proc hasPath*(
    db: AristoDbRef;                  # Database
    root: VertexID;
    path: openArray[byte];            # Key of database record
      ): Result[bool,(VertexID,AristoError)] =
  ## Variant of `fetchPayload()`
  ##
  if path.len == 0:
    return err((VertexID(0),LeafKeyInvalid))
  let rc = db.fetchPayloadImpl(root, path)
  if rc.isOk:
    return ok(true)
  if rc.error[1] == FetchPathNotFound:
    return ok(false)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
