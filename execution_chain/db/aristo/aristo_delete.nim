# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie delete funcionality
## ==============================================
##

{.push raises: [].}

import
  std/typetraits,
  eth/common/hashes,
  results,
  ./aristo_delete/delete_subtree,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike, aristo_layers]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc branchStillNeeded(branch: BranchData, removed: int8): Result[int8,void] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1'i8
  for n in 0'i8 .. 15'i8:
    if n == removed:
      continue

    if branch.bVid(uint8 n).isValid:
      if 0 <= nibble:
        return ok(-1)
      nibble = n
  if 0 <= nibble:
    return ok(nibble)
  # Oops, degenerated branch node
  err()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc deleteImpl(
    db: AristoTxRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
      ): Result[Vertex, AristoError] =
  ## Removes the last node in the hike and returns the updated leaf in case
  ## a branch collapsed

  # Remove leaf entry
  let lf = hike.legs[^1].wp
  if lf.vtx.vType notin Leaves:
    return err(DelLeafExpexted)

  db.layersResVtx((hike.root, lf.vid))

  if hike.legs.len == 1:
    # This was the last node in the trie, meaning we don't have any branches or
    # leaves to update
    return ok(emptyVertex)

  if hike.legs[^2].wp.vtx.vType notin Branches:
    return err(DelBranchExpexted)

  # Get current `Branch` vertex `br`
  let br = hike.legs[^2].wp
  var brVtx = br.vtx
  let nbl = brVtx.branch.branchStillNeeded(hike.legs[^2].nibble).valueOr:
      return err(DelBranchWithoutRefs)

  # Clear keys that include `br` - `br` itself will be replaced below
  db.layersResKeys(hike, skip = 2)

  if 0 <= nbl:
    # Branch has only one entry - move that entry to where the branch was and
    # update its path

    # Get child vertex (there must be one after a `Branch` node)
    let
      vid = brVtx.branch.bVid(uint8 nbl)
      nxt = db.getVtx (hike.root, vid)
    if not nxt.isValid:
      return err(DelVidStaleVtx)

    db.layersResVtx((hike.root, vid))
    let
      pfx =
        if brVtx.vType == Branch:
          NibblesBuf.nibble(nbl.byte)
        else:
          brVtx.branch.pfx[] & NibblesBuf.nibble(nbl.byte)
      vtx =
        case nxt.vType
        of Empty:
          raiseAssert "unexpected empty vtx"
        of AccLeaf:
          Vertex.initAccLeaf(pfx & nxt.accLeaf.pfx, nxt.accLeaf.account, nxt.accLeaf.stoID)
        of StoLeaf:
          Vertex.initStoLeaf(pfx & nxt.stoLeaf.pfx, nxt.stoLeaf.stoData)
        of Branch:
          Vertex.initExtBranch(pfx, nxt.branch.startVid, nxt.branch.used)
        of ExtBranch:
          Vertex.initExtBranch(pfx & nxt.branch.pfx[], nxt.branch.startVid, nxt.branch.used)

    # Put the new vertex at the id of the obsolete branch
    db.layersPutVtx((hike.root, br.vid), vtx)

    if vtx.vType in Leaves:
      ok(vtx)
    else:
      ok(emptyVertex)
  else:
    # Clear the removed leaf from the branch (that still contains other children)
    discard brVtx.branch.setUsed(uint8 hike.legs[^2].nibble, false)
    discard db.layersUpdate((hike.root, br.vid), brVtx) 

    ok(emptyVertex)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deleteAccountRecord*(
    db: AristoTxRef;
    accPath: Hash32;
      ): Result[void,AristoError] =
  ## Delete the account leaf entry addressed by the argument `path`. If this
  ## leaf entry references a storage tree, this one will be deleted as well.
  ##
  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return ok() # Trying to delete something that doesn't exist is ok
    return err(error)
  let stoID = accHike.legs[^1].wp.vtx.accLeaf.stoID

  # Delete storage tree if present
  if stoID.isValid:
    ?db.delStoTreeImpl(stoID.vid, accPath)

  let otherLeaf = ?db.deleteImpl(accHike)

  db.layersPutAccLeaf(accPath, Opt.none(AccLeafData))

  if otherLeaf.isValid:
    db.layersPutAccLeaf(
      Hash32(getBytes(NibblesBuf.fromBytes(accPath.data).replaceSuffix(otherLeaf.pfx))),
      Opt.some(otherLeaf.accLeaf),
    )

  ok()

proc deleteStorageData*(
    db: AristoTxRef;
    accPath: Hash32;          # Implies storage data tree
    stoPath: Hash32;
      ): Result[void,AristoError] =
  ## For a given account argument `accPath`, this function deletes the
  ## argument `stoPath` from the associated storage tree (if any, at all.) If
  ## the if the argument `stoPath` deleted was the last one on the storage tree,
  ## account leaf referred to by `accPath` will be updated so that it will
  ## not refer to a storage tree anymore.
  ##

  let
    mixPath = mixUp(accPath, stoPath)
    stoLeaf = db.cachedStoLeaf(mixPath)

  if stoLeaf == Opt.some(Opt.none(StoLeafData)):
    return ok() # Trying to delete something that doesn't exist is ok

  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return ok() # Trying to delete something that doesn't exist is ok
    return err(error)

  let wpAcc = accHike.legs[^1].wp
  var accVtx = wpAcc.vtx
  let stoID = accVtx.accLeaf.stoID

  if not stoID.isValid:
    return ok() # Trying to delete something that doesn't exist is ok

  let stoNibbles = NibblesBuf.fromBytes(stoPath.data)
  var stoHike: Hike
  stoNibbles.hikeUp(stoID.vid, db, stoLeaf, stoHike).isOkOr:
    if error[1] in HikeAcceptableStopsNotFound:
      return ok()
    return err(error[1])

  # Mark account path Merkle keys for update - the leaf key is not stored so no
  # need to mark it
  db.layersResKeys(accHike, skip = 1)

  let otherLeaf = ?db.deleteImpl(stoHike)
  db.layersPutStoLeaf(mixPath, Opt.none(StoLeafData))

  if otherLeaf.isValid:
    let leafMixPath =
      mixUp(accPath, Hash32(getBytes(stoNibbles.replaceSuffix(otherLeaf.pfx))))
    db.layersPutStoLeaf(leafMixPath, Opt.some(otherLeaf.stoLeaf))

  # If there was only one item (that got deleted), update the account as well
  if stoHike.legs.len == 1:
    # De-register the deleted storage tree from the account record
    accVtx.accLeaf.stoID.isValid = false
    discard db.layersUpdate((accHike.root, wpAcc.vid), accVtx) # Dup on modify
    
    db.layersPutAccLeaf(accPath, Opt.some(accVtx.accLeaf))

  ok()

proc deleteStorageTree*(
    db: AristoTxRef;                   # Database, top layer
    accPath: Hash32;                   # Implies storage data tree
      ): Result[void,AristoError] =
  ## Variant of `deleteStorageData()` for purging the whole storage tree
  ## associated to the account argument `accPath`.
  ##
  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return ok() # Trying to delete something that doesn't exist is ok
    return err(error)

  let wpAcc = accHike.legs[^1].wp
  var accVtx = wpAcc.vtx
  let stoID = accVtx.accLeaf.stoID

  if not stoID.isValid:
    return ok() # Trying to delete something that doesn't exist is ok

  # Mark account path Merkle keys for update, except for the vtx we update below
  db.layersResKeys(accHike, skip = 1)

  ?db.delStoTreeImpl(stoID.vid, accPath)

  # De-register the deleted storage tree from the accounts record
  accVtx.accLeaf.stoID.isValid = false
  discard db.layersUpdate((accHike.root, wpAcc.vid), accVtx) # Dup on modify
  
  db.layersPutAccLeaf(accPath, Opt.some(accVtx.accLeaf))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
