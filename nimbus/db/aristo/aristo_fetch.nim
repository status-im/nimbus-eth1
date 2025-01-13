# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  eth/common/[base, hashes],
  results,
  "."/[aristo_compute, aristo_desc, aristo_get, aristo_layers, aristo_hike]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc retrieveLeaf(
    db: AristoTxRef;
    root: VertexID;
    path: Hash32;
      ): Result[VertexRef,AristoError] =
  for step in stepUp(NibblesBuf.fromBytes(path.data), root, db):
    let vtx = step.valueOr:
      if error in HikeAcceptableStopsNotFound:
        return err(FetchPathNotFound)
      return err(error)

    if vtx.vType == Leaf:
      return ok vtx

  return err(FetchPathNotFound)

proc cachedAccLeaf*(db: AristoTxRef; accPath: Hash32): Opt[VertexRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetAccLeaf(accPath) or
    db.db.accLeaves.get(accPath) or
    Opt.none(VertexRef)

proc cachedStoLeaf*(db: AristoTxRef; mixPath: Hash32): Opt[VertexRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetStoLeaf(mixPath) or
    db.db.stoLeaves.get(mixPath) or
    Opt.none(VertexRef)

proc retrieveAccountLeaf(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[VertexRef,AristoError] =
  if (let leafVtx = db.cachedAccLeaf(accPath); leafVtx.isSome()):
    if not leafVtx[].isValid():
      return err(FetchPathNotFound)
    return ok leafVtx[]

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let
    leafVtx = db.retrieveLeaf(VertexID(1), accPath).valueOr:
      if error == FetchPathNotFound:
        db.db.accLeaves.put(accPath, nil)
      return err(error)

  db.db.accLeaves.put(accPath, leafVtx)

  ok leafVtx

proc retrieveMerkleHash(
    db: AristoTxRef;
    root: VertexID;
      ): Result[Hash32,AristoError] =
  let key =
    db.computeKey((root, root)).valueOr:
      if error in [GetVtxNotFound, GetKeyNotFound]:
        return ok(emptyRoot)
      return err(error)

  ok key.to(Hash32)

proc hasAccountPayload(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[bool,AristoError] =
  let error = db.retrieveAccountLeaf(accPath).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

proc fetchStorageIdImpl(
    db: AristoTxRef;
    accPath: Hash32;
    enaStoRootMissing = false;
      ): Result[VertexID,AristoError] =
  ## Helper function for retrieving a storage (vertex) ID for a given account.
  let
    leafVtx = ?db.retrieveAccountLeaf(accPath)
    stoID = leafVtx[].lData.stoID

  if stoID.isValid:
    ok stoID.vid
  elif enaStoRootMissing:
    err(FetchPathStoRootMissing)
  else:
    err(FetchPathNotFound)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc fetchAccountHike*(
    db: AristoTxRef;                   # Database
    accPath: Hash32;                  # Implies a storage ID (if any)
    accHike: var Hike
      ): Result[void,AristoError] =
  ## Expand account path to account leaf or return failure

  # Prefer the leaf cache so as not to burden the lower layers
  let leaf = db.cachedAccLeaf(accPath)
  if leaf == Opt.some(VertexRef(nil)):
    return err(FetchAccInaccessible)

  accPath.hikeUp(VertexID(1), db, leaf, accHike).isOkOr:
    return err(FetchAccInaccessible)

  # Extract the account payload from the leaf
  if accHike.legs.len == 0 or accHike.legs[^1].wp.vtx.vType != Leaf:
    return err(FetchAccPathWithoutLeaf)

  assert accHike.legs[^1].wp.vtx.lData.pType == AccountData

  ok()

proc fetchStorageID*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[VertexID,AristoError] =
  ## Public helper function for retrieving a storage (vertex) ID for a given account. This
  ## function returns a separate error `FetchPathStoRootMissing` (from `FetchPathNotFound`)
  ## if the account for the argument path `accPath` exists but has no storage root.
  ##
  db.fetchStorageIdImpl(accPath, enaStoRootMissing=true)

proc retrieveStoragePayload(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[UInt256,AristoError] =
  let mixPath = mixUp(accPath, stoPath)

  if (let leafVtx = db.cachedStoLeaf(mixPath); leafVtx.isSome()):
    if not leafVtx[].isValid():
      return err(FetchPathNotFound)
    return ok leafVtx[].lData.stoData

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let leafVtx = db.retrieveLeaf(? db.fetchStorageIdImpl(accPath), stoPath).valueOr:
    if error == FetchPathNotFound:
      db.db.stoLeaves.put(mixPath, nil)
    return err(error)

  db.db.stoLeaves.put(mixPath, leafVtx)

  ok leafVtx.lData.stoData

proc hasStoragePayload(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[bool,AristoError] =
  let error = db.retrieveStoragePayload(accPath, stoPath).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchLastSavedState*(
    db: AristoTxRef;
      ): Result[SavedState,AristoError] =
  ## Wrapper around `getLstBe()`. The function returns the state of the last
  ## saved state. This is a Merkle hash tag for vertex with ID 1 and a bespoke
  ## `uint64` identifier (may be interpreted as block number.)
  # TODO store in frame!!
  db.db.getLstBe()

proc fetchAccountRecord*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[AristoAccount,AristoError] =
  ## Fetch an account record from the database indexed by `accPath`.
  ##
  let leafVtx = ? db.retrieveAccountLeaf(accPath)
  assert leafVtx.lData.pType == AccountData   # debugging only

  ok leafVtx.lData.account

proc fetchStateRoot*(
    db: AristoTxRef;
      ): Result[Hash32,AristoError] =
  ## Fetch the Merkle hash of the account root.
  db.retrieveMerkleHash(VertexID(1))

proc hasPathAccount*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[bool,AristoError] =
  ## For an account record indexed by `accPath` query whether this record exists
  ## on the database.
  ##
  db.hasAccountPayload(accPath)

proc fetchStorageData*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[UInt256,AristoError] =
  ## For a storage tree related to account `accPath`, fetch the data record
  ## from the database indexed by `path`.
  ##
  db.retrieveStoragePayload(accPath, stoPath)

proc fetchStorageRoot*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[Hash32,AristoError] =
  ## Fetch the Merkle hash of the storage root related to `accPath`.
  let stoID = db.fetchStorageIdImpl(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(emptyRoot) # no sub-tree
    return err(error)
  db.retrieveMerkleHash(stoID)

proc hasPathStorage*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether the data
  ## record indexed by `path` exists on the database.
  ##
  db.hasStoragePayload(accPath, stoPath)

proc hasStorageData*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether there
  ## is a non-empty data storage area at all.
  ##
  let stoID = db.fetchStorageIdImpl(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(false) # no sub-tree
    return err(error)
  ok stoID.isValid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
