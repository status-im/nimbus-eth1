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
  std/typetraits,
  eth/common,
  results,
  "."/[aristo_compute, aristo_desc, aristo_get, aristo_hike]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func mustBeGeneric(
    root: VertexID;
      ): Result[void,AristoError] =
  ## Verify that `root` is neither from an accounts tree nor a strorage tree.
  if not root.isValid:
    return err(FetchRootVidMissing)
  elif root == VertexID(1):
    return err(FetchAccRootNotAccepted)
  elif LEAST_FREE_VID <= root.distinctBase:
    return err(FetchStoRootNotAccepted)
  ok()


proc retrievePayload(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[PayloadRef,AristoError] =
  if path.len == 0:
    return err(FetchPathInvalid)

  for step in stepUp(NibblesBuf.fromBytes(path), root, db):
    let vtx = step.valueOr:
      if error in HikeAcceptableStopsNotFound:
        return err(FetchPathNotFound)
      return err(error)

    if vtx.vType == Leaf:
      return ok vtx.lData

  return err(FetchPathNotFound)

proc retrieveMerkleHash(
    db: AristoDbRef;
    root: VertexID;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  let key = block:
    if updateOk:
      db.computeKey(root).valueOr:
        if error == GetVtxNotFound:
          return ok(EMPTY_ROOT_HASH)
        return err(error)
    else:
      db.getKeyRc(root).valueOr:
        if error == GetKeyNotFound:
          return ok(EMPTY_ROOT_HASH) # empty sub-tree
        return err(error)
  ok key.to(Hash256)


proc hasPayload(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[bool,AristoError] =
  if path.len == 0:
    return err(FetchPathInvalid)

  let error = db.retrievePayload(root, path).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc fetchAccountHike*(
    db: AristoDbRef;                   # Database
    accPath: Hash256;          # Implies a storage ID (if any)
      ): Result[Hike,AristoError] =
  ## Verify that the `accPath` argument properly referres to a storage root
  ## vertex ID. The function will reset the keys along the `accPath` for
  ## being modified.
  ##
  ## On success, the function will return an account leaf pair with the leaf
  ## vertex and the vertex ID.
  ##
  # Expand vertex path to account leaf
  var hike = accPath.hikeUp(VertexID(1), db).valueOr:
    return err(FetchAccInaccessible)

  # Extract the account payload from the leaf
  let wp = hike.legs[^1].wp
  if wp.vtx.vType != Leaf:
    return err(FetchAccPathWithoutLeaf)
  assert wp.vtx.lData.pType == AccountData            # debugging only

  ok(move(hike))


proc fetchStorageID*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[VertexID,AristoError] =
  ## Public helper function fro retrieving a storage (vertex) ID for a
  ## given account.
  let
    payload = db.retrievePayload(VertexID(1), accPath.data).valueOr:
      if error == FetchAccInaccessible:
        return err(FetchPathNotFound)
      return err(error)

    stoID = payload.stoID

  if not stoID.isValid:
    return err(FetchPathNotFound)

  ok stoID

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchLastSavedState*(
    db: AristoDbRef;
      ): Result[SavedState,AristoError] =
  ## Wrapper around `getLstUbe()`. The function returns the state of the last
  ## saved state. This is a Merkle hash tag for vertex with ID 1 and a bespoke
  ## `uint64` identifier (may be interpreted as block number.)
  db.getLstUbe()


proc fetchAccountRecord*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[AristoAccount,AristoError] =
  ## Fetch an account record from the database indexed by `accPath`.
  ##
  let pyl = ? db.retrievePayload(VertexID(1), accPath.data)
  assert pyl.pType == AccountData   # debugging only
  ok pyl.account

proc fetchAccountState*(
    db: AristoDbRef;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the account root.
  db.retrieveMerkleHash(VertexID(1), updateOk)

proc hasPathAccount*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[bool,AristoError] =
  ## For an account record indexed by `accPath` query whether this record exists
  ## on the database.
  ##
  db.hasPayload(VertexID(1), accPath.data)


proc fetchGenericData*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[Blob,AristoError] =
  ## For a generic sub-tree starting at `root`, fetch the data record
  ## indexed by `path`.
  ##
  ? root.mustBeGeneric()
  let pyl = ? db.retrievePayload(root, path)
  assert pyl.pType == RawData   # debugging only
  ok pyl.rawBlob

proc fetchGenericState*(
    db: AristoDbRef;
    root: VertexID;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the argument `root`.
  db.retrieveMerkleHash(root, updateOk)

proc hasPathGeneric*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[bool,AristoError] =
  ## For a generic sub-tree starting at `root` and indexed by `path`, query
  ## whether this record exists on the database.
  ##
  ? root.mustBeGeneric()
  db.hasPayload(root, path)


proc fetchStorageData*(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: openArray[byte];
      ): Result[Blob,AristoError] =
  ## For a storage tree related to account `accPath`, fetch the data record
  ## from the database indexed by `path`.
  ##
  let pyl = ? db.retrievePayload(? db.fetchStorageID accPath, stoPath)
  assert pyl.pType == RawData   # debugging only
  ok pyl.rawBlob

proc fetchStorageState*(
    db: AristoDbRef;
    accPath: Hash256;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the storage root related to `accPath`.
  let stoID = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(EMPTY_ROOT_HASH) # no sub-tree
    return err(error)
  db.retrieveMerkleHash(stoID, updateOk)

proc hasPathStorage*(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: openArray[byte];
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether the data
  ## record indexed by `path` exists on the database.
  ##
  db.hasPayload(? db.fetchStorageID accPath, stoPath)

proc hasStorageData*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether there
  ## is a non-empty data storage area at all.
  ##
  let stoID = db.fetchStorageID(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(false) # no sub-tree
    return err(error)
  ok stoID.isValid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
