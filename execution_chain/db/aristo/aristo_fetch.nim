# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  std/[atomics, typetraits],
  eth/common/[base, hashes],
  results,
  "."/[aristo_compute, aristo_desc, aristo_fetch_stats, aristo_get, aristo_layers,
       aristo_hike, aristo_vid]

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

template cacheAccLeaf(db: AristoTxRef; accPath: Hash32; cached: CachedAccLeaf) =
  when compileOption("threads"):
    db.db.accLeaves.put(accPath, cached)

template cacheStoLeaf(db: AristoTxRef; mixPath: Hash32; cached: CachedStoLeaf) =
  when compileOption("threads"):
    db.db.stoLeaves.put(mixPath, cached)

proc cachedAccLeaf*(db: AristoTxRef; accPath: Hash32): Opt[AccLeafRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetAccLeaf(accPath).isErrOr:
    return Opt.some(value)

  when compileOption("threads"):
    db.db.accLeaves.withGet(accPath, cached):
      return Opt.some(cached.toLeaf())
    do:
      return Opt.none(AccLeafRef)
  else:
    Opt.none(AccLeafRef)

proc cachedStoLeaf*(db: AristoTxRef; mixPath: Hash32): Opt[StoLeafRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetStoLeaf(mixPath).isErrOr:
    return Opt.some(value)

  when compileOption("threads"):
    db.db.stoLeaves.withGet(mixPath, cached):
      return Opt.some(cached.toLeaf())
    do:
      return Opt.none(StoLeafRef)
  else:
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
        discard db.db.lookupsHits.fetchAdd(1, moRelaxed)
      else:
        discard db.db.lookupsLower.fetchAdd(1, moRelaxed)

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
    of BoundaryNode:
      # Stateless-only boundary: child absent from witness, not traversable.
      # Same divergence-vs-gap distinction as `aristo_hike.step()`.
      let vtx = BoundaryNodeRef(vtx[0])
      countHitOrLower()
      if path.slice(sl).sharedPrefixLen(vtx.pfx) < vtx.pfx.len:
        return err FetchPathNotFound
      return err HikeBranchUnresolvedEdge
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

proc retrieveStoLeaf(
    db: AristoTxRef;
    stoID: VertexID;
    stoPath: Hash32;
    hint: int;
      ): Result[VertexRef,AristoError] =
  ## Walk the storage trie as far as the in-memory caches reach, then probe the
  ## static vids from `hint` down to the first uncached level before reading
  ## the rest of the path from the backend.
  let full = NibblesBuf.fromBytes(stoPath.data)
  var
    path = full
    next = stoID
    level = 0

  while true:
    let (vtx, common, nxt) = step(path, (stoID, next), db, {GetVtxFlag.CacheOnly}).valueOr:
      if error == GetVtxNotCached:
        break
      if error in HikeAcceptableStopsNotFound:
        return err(FetchPathNotFound)
      return err(error)
    if vtx.vType in Leaves:
      return ok vtx
    path = path.slice(common)
    level += common
    next = nxt

  for sl in countdown(hint, level + 1):
    let vtx = db.getVtxRc((stoID, full.staticVid(sl))).valueOr:
      continue
    case vtx[0].vType
    of Leaves:
      return
        if LeafRef(vtx[0]).pfx != full.slice(sl):
          err FetchPathNotFound
        else:
          ok vtx[0]
    of BoundaryNode:
      let vtx = BoundaryNodeRef(vtx[0])
      if full.slice(sl).sharedPrefixLen(vtx.pfx) < vtx.pfx.len:
        return err FetchPathNotFound
      return err HikeBranchUnresolvedEdge
    of ExtBranch:
      let vtx = ExtBranchRef(vtx[0])
      if vtx.pfx != full.slice(sl, sl + vtx.pfx.len):
        return err FetchPathNotFound
      next = vtx.bVid(full[sl + vtx.pfx.len])
      if not next.isValid():
        return err FetchPathNotFound
      path = full.slice(sl + vtx.pfx.len + 1)
      break
    of Branch:
      let vtx = BranchRef(vtx[0])
      next = vtx.bVid(full[sl])
      if not next.isValid():
        return err FetchPathNotFound
      path = full.slice(sl + 1)
      break

  db.retrieveLeaf(stoID, path, next)

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
      db.cacheAccLeaf(accPath, emptyCachedAccLeaf)
    return err(error)

  if staticVtx.isValid():
    db.cacheAccLeaf(accPath, CachedAccLeaf.init(staticVtx.pfx, staticVtx.account, staticVtx.stoID, staticVtx.stoHint))
    return ok staticVtx

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let
    leafVtx = db.retrieveLeaf(STATE_ROOT_VID, path, next).valueOr:
      if error == FetchPathNotFound:
        # The branch was the deepest level where a vertex actually existed
        # meaning that it was a hit - else searches for non-existing paths would
        # skew the results towards more depth than exists in the MPT
        discard db.db.lookupsHits.fetchAdd(1, moRelaxed)
        db.cacheAccLeaf(accPath, emptyCachedAccLeaf)
      return err(error)

  discard db.db.lookupsHigher.fetchAdd(1, moRelaxed)

  let accLeaf = AccLeafRef(leafVtx)
  db.cacheAccLeaf(accPath, CachedAccLeaf.init(accLeaf.pfx, accLeaf.account, accLeaf.stoID, accLeaf.stoHint))

  ok accLeaf

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

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc fetchAccountHike*(
    db: AristoTxRef;
    accPath: Hash32;
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
  ## Public helper function for retrieving a storage (vertex) ID for a given account.
  ##
  ## Returns `VertexID()` if the account has no storage and `err(FetchPathNotFound)`
  ## if the account does not exist.
  let
    leafVtx = ?db.retrieveAccLeaf(accPath)
    stoID = leafVtx[].stoID

  ok if stoID.isValid:
    stoID.vid
  else:
    default(VertexID)

proc fetchStorageInfo*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[(VertexID, int),AristoError] =
  ## Storage root vid and static depth hint, `(0, 0)` when there is no storage
  let leafVtx = ?db.retrieveAccLeaf(accPath)
  ok if leafVtx.stoID.isValid:
    (leafVtx.stoID.vid, int leafVtx.stoHint)
  else:
    (default(VertexID), 0)

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

proc fetchAccountImpl(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[AristoAccount,AristoError] =
  let leafVtx = ? db.retrieveAccLeaf(accPath)

  ok leafVtx.account

proc fetchAccount*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[AristoAccount,AristoError] =
  ## Fetch an account record from the database indexed by `accPath`.
  ##
  when LeafFetchStats:
    let
      counters = fetchCounters()
      before = counters.mark()
    result = db.fetchAccountImpl(accPath)
    counters.recordAccFetch(before)
  else:
    db.fetchAccountImpl(accPath)

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

proc hasAccount*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[bool,AristoError] =
  ## For an account record indexed by `accPath` query whether this record exists
  ## on the database.
  ##
  let error = db.retrieveAccLeaf(accPath).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

proc fetchSlotImpl(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[UInt256,AristoError] =
  let mixPath = mixUp(accPath, stoPath)

  db.layersGetStoLeaf(mixPath).isErrOr:
    # Found in the layers so we don't need to copy into the cache
    # because the value will be updated from the layers during persist
    return ok value.toStoData()

  when compileOption("threads"):
    db.db.stoLeaves.withGet(mixPath, cached):
      return ok cached.toStoData()

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database

  when LeafFetchStats:
    let
      accCounters = fetchCounters()
      accBefore = accCounters.mark()

  let (stoID, hint) = ?db.fetchStorageInfo(accPath)

  when LeafFetchStats:
    accCounters.recordSlotAccLookup(accBefore)

  if not stoID.isValid():
    db.cacheStoLeaf(mixPath, emptyCachedStoLeaf)
    return ok 0'u256

  let leafRc =
    if db.db.stoStatic and 0 < hint:
      db.retrieveStoLeaf(stoID, stoPath, hint)
    else:
      db.retrieveLeaf(stoID, NibblesBuf.fromBytes(stoPath.data))
  if leafRc.isErr:
    if leafRc.error == FetchPathNotFound:
      db.cacheStoLeaf(mixPath, emptyCachedStoLeaf)
      return ok 0'u256

    # `HikeDanglingEdge` / `HikeBranchUnresolvedEdge`: missing state in
    # witness or not-yet-fetched node, or a backend (db corruption) error.
    # Can't know if slot is absent.
    return err(leafRc.error)

  let leaf = StoLeafRef(leafRc.value)
  db.cacheStoLeaf(mixPath, CachedStoLeaf.init(leaf.pfx, leaf.stoData))
  return ok leaf.toStoData()

proc fetchSlot*(
    db: AristoTxRef;
    accPath: Hash32;
    stoPath: Hash32;
      ): Result[UInt256,AristoError] =
  ## For a storage tree related to account `accPath`, fetch the data record
  ## from the database indexed by `path`. Returns err(FetchPathNotFound) if the
  ## account does not exist and 0'u256 if the account has not stored anything
  ## at the given slot
  when LeafFetchStats:
    let
      counters = fetchCounters()
      before = counters.mark()
    result = db.fetchSlotImpl(accPath, stoPath)
    counters.recordSlotFetch(before)
  else:
    db.fetchSlotImpl(accPath, stoPath)

proc fetchStorageRoot*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[Hash32,AristoError] =
  ## Fetch the Merkle hash of the storage root related to `accPath`.
  let stoID = ?db.fetchStorageID(accPath)

  if stoID.isValid():
    db.retrieveMerkleHash(stoID)
  else:
    ok emptyRoot

proc hasStorage*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether there
  ## is a non-empty data storage area at all.
  ##
  let stoID = ?db.fetchStorageID(accPath)
  ok stoID.isValid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
