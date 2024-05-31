# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  "."/[aristo_desc, aristo_get, aristo_hike]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchPayloadImpl(
    rc: Result[Hike,(VertexID,AristoError,Hike)];
      ): Result[PayloadRef,(VertexID,AristoError)] =
  if rc.isErr:
    if rc.error[1] in HikeAcceptableStopsNotFound:
      return err((rc.error[0], FetchPathNotFound))
    return err((rc.error[0], rc.error[1]))
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
  ## leaf vertex. This function is complementary to `mergePayload()`.
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

proc fetchLastSavedState*(
    db: AristoDbRef;
      ): Result[SavedState,AristoError] =
  ## Wrapper around `getLstUbe()`. The function returns the state of the last
  ## saved state. This is a Merkle hash tag for vertex with ID 1 and a bespoke
  ## `uint64` identifier (may be interpreted as block number.)
  db.getLstUbe()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
