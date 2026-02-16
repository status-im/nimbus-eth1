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
  "."/[aristo_compute, aristo_desc, aristo_get, aristo_layers, aristo_hike, aristo_vid]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc retrieveLeaf(
    db: AristoTxRef;
    root: VertexID;
    path: NibblesBuf;
    next = VertexID(0),
      ): Result[VertexRef,AristoError] =
  for step in stepUp(path, root, db, next):
    let vtx = step.valueOr:
      if error in HikeAcceptableStopsNotFound:
        return err(FetchPathNotFound)
      return err(error)

    if vtx.vType in Leaves:
      return ok vtx

  return err(FetchPathNotFound)

proc cachedAccLeaf*(db: AristoTxRef; accPath: Hash32): Opt[AccLeafRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetAccLeaf(accPath) or
    db.db.accLeaves.get(accPath) or
    Opt.none(AccLeafRef)

proc cachedStoLeaf*(db: AristoTxRef; mixPath: Hash32): Opt[StoLeafRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetStoLeaf(mixPath) or
    db.db.stoLeaves.get(mixPath) or
    Opt.none(StoLeafRef)

proc retrieveAccStatic(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[(AccLeafRef, NibblesBuf, VertexID),AristoError] =
  # A static VertexID essentially splits the path into a prefix encoded in the
  # vid and the rest of the path stored as normal - here, instead of traversing
  # the trie from the root and selecting a path nibble by nibble we travers the
  # trie starting at `staticLevel` and search towards the root until either we
  # hit the node we're looking for or at least a branch from which we can
  # shorten the lookup.
  let staticLevel = db.db.getStaticLevel()

  var path = NibblesBuf.fromBytes(accPath.data)
  var next: VertexID

  for sl in countdown(staticLevel, 0):
    template countHitOrLower() =
      if sl == staticLevel:
        db.db.lookups.hits += 1
      else:
        db.db.lookups.lower += 1

    let
      svid = path.staticVid(sl)
      vtx = db.getVtxRc((STATE_ROOT_VID, svid)).valueOr:
        # Either the node doesn't exist or our guess used too many nibbles and
        # the trie is not yet this deep at the given path - either way, we'll
        # try a less deep guess which will result either in a branch,
        # non-matching leaf or more missing verticies.
        continue

    case vtx[0].vType
    of Leaves:
      let vtx = AccLeafRef(vtx[0])

      countHitOrLower()
      return
        if vtx.pfx != path.slice(sl): # Same prefix, different path
          err FetchPathNotFound
        else:
          ok (vtx, path, next)
    of ExtBranch:
      let vtx = ExtBranchRef(vtx[0])

      if vtx.pfx != path.slice(sl, sl + vtx.pfx.len): # Same prefix, different path
        countHitOrLower()
        return err FetchPathNotFound

      let nibble = path[sl + vtx.pfx.len]
      next = vtx.bVid(nibble)

      if not next.isValid():
        countHitOrLower()
        return err FetchPathNotFound

      path = path.slice(sl + vtx.pfx.len + 1)

      break # Continue the search down the branch children, starting at `next`
    of Branch: # Same as ExtBranch with vtx.pfx.len == 0!
      let vtx = BranchRef(vtx[0])

      let nibble = path[sl]
      next = vtx.bVid(nibble)

      if not next.isValid():
        countHitOrLower()
        return err FetchPathNotFound

      path = path.slice(sl + 1)
      break # Continue the search down the branch children, starting at `next`

  # We end up here when we have to continue the search down a branch
  ok (nil, path, next)

proc retrieveAccLeaf(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[AccLeafRef,AristoError] =
  if (let leafVtx = db.cachedAccLeaf(accPath); leafVtx.isSome()):
    if not leafVtx[].isValid():
      return err(FetchPathNotFound)
    return ok leafVtx[]

  let (staticVtx, path, next) = db.retrieveAccStatic(accPath).valueOr:
    if error == FetchPathNotFound:
      db.db.accLeaves.put(accPath, nil)
    return err(error)

  if staticVtx.isValid():
    db.db.accLeaves.put(accPath, staticVtx)
    return ok staticVtx

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let
    leafVtx = db.retrieveLeaf(STATE_ROOT_VID, path, next).valueOr:
      if error == FetchPathNotFound:
        # The branch was the deepest level where a vertex actually existed
        # meaning that it was a hit - else searches for non-existing paths would
        # skew the results towards more depth than exists in the MPT
        db.db.lookups.hits += 1
        db.db.accLeaves.put(accPath, nil)
      return err(error)

  db.db.lookups.higher += 1

  db.db.accLeaves.put(accPath, AccLeafRef(leafVtx))

  ok AccLeafRef(leafVtx)

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
  let error = db.retrieveAccLeaf(accPath).errorOr:
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
    leafVtx = ?db.retrieveAccLeaf(accPath)
    stoID = leafVtx[].stoID

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
  if leaf == Opt.some(AccLeafRef(nil)):
    return err(FetchAccInaccessible)

  accPath.hikeUp(STATE_ROOT_VID, db, leaf, accHike).isOkOr:
    return err(FetchAccInaccessible)

  # Extract the account payload from the leaf
  if accHike.legs.len == 0 or accHike.legs[^1].wp.vtx.vType != AccLeaf:
    return err(FetchAccPathWithoutLeaf)

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
    return ok leafVtx[].stoData

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let leafVtx = db.retrieveLeaf(
      ? db.fetchStorageIdImpl(accPath), NibblesBuf.fromBytes(stoPath.data)).valueOr:
    if error == FetchPathNotFound:
      db.db.stoLeaves.put(mixPath, nil)
    return err(error)

  db.db.stoLeaves.put(mixPath, StoLeafRef(leafVtx))

  ok StoLeafRef(leafVtx).stoData

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

proc fetchLastCheckpoint*(
    db: AristoTxRef;
      ): Result[BlockNumber,AristoError] =
  ## Wrapper around `getLstBe()`. The function returns the state of the last
  ## saved state. This is a Merkle hash tag for vertex with ID 1 and a bespoke
  ## `uint64` identifier (may be interpreted as block number.)
  if db.blockNumber.isSome():
    return ok db.blockNumber.get()

  let state = ?db.db.getLstBe()
  ok state.serial

proc fetchAccountRecord*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[AristoAccount,AristoError] =
  ## Fetch an account record from the database indexed by `accPath`.
  ##
  let leafVtx = ? db.retrieveAccLeaf(accPath)

  ok leafVtx.account

proc fetchStateRoot*(
    db: AristoTxRef;
      ): Result[Hash32,AristoError] =
  ## Fetch the Merkle hash of the account root.
  let key =
    db.computeStateRoot().valueOr:
      if error in [GetVtxNotFound, GetKeyNotFound]:
        return ok(emptyRoot)
      return err(error)

  ok key.to(Hash32)

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
