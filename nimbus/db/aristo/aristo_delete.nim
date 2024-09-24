# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  eth/common,
  results,
  ./aristo_delete/[delete_helpers, delete_subtree],
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike, aristo_layers]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: VertexRef, removed: int): Result[int,void] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1
  for n in 0 .. 15:
    if n == removed:
      continue

    if vtx.bVid[n].isValid:
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
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
      ): Result[VertexRef,AristoError] =
  ## Removes the last node in the hike and returns the updated leaf in case
  ## a branch collapsed

  # Remove leaf entry
  let lf = hike.legs[^1].wp
  if lf.vtx.vType != Leaf:
    return err(DelLeafExpexted)

  db.disposeOfVtx((hike.root, lf.vid))

  if hike.legs.len == 1:
    # This was the last node in the trie, meaning we don't have any branches or
    # leaves to update
    return ok(nil)

  if hike.legs[^2].wp.vtx.vType != Branch:
    return err(DelBranchExpexted)

  # Get current `Branch` vertex `br`
  let
    br = hike.legs[^2].wp
    nbl = br.vtx.branchStillNeeded(hike.legs[^2].nibble).valueOr:
      return err(DelBranchWithoutRefs)

  # Clear all Merkle hash keys up to the root key
  for n in 0 .. hike.legs.len - 2:
    let vid = hike.legs[n].wp.vid
    db.layersResKey((hike.root, vid))

  if 0 <= nbl:
    # Branch has only one entry - move that entry to where the branch was and
    # update its path

    # Get child vertex (there must be one after a `Branch` node)
    let
      vid = br.vtx.bVid[nbl]
      nxt = db.getVtx (hike.root, vid)
    if not nxt.isValid:
      return err(DelVidStaleVtx)

    db.disposeOfVtx((hike.root, vid))

    let vtx =
      case nxt.vType
      of Leaf:
        VertexRef(
          vType: Leaf,
          pfx:  br.vtx.pfx & NibblesBuf.nibble(nbl.byte) & nxt.pfx,
          lData: nxt.lData)

      of Branch:
        VertexRef(
          vType: Branch,
          pfx:  br.vtx.pfx & NibblesBuf.nibble(nbl.byte) & nxt.pfx,
          bVid: nxt.bVid)

    # Put the new vertex at the id of the obsolete branch
    db.layersPutVtx((hike.root, br.vid), vtx)

    if vtx.vType == Leaf:
      ok(vtx)
    else:
      ok(nil)
  else:
    # Clear the removed leaf from the branch (that still contains other children)
    let brDup = br.vtx.dup
    brDup.bVid[hike.legs[^2].nibble] = VertexID(0)
    db.layersPutVtx((hike.root, br.vid), brDup)

    ok(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deleteAccountRecord*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[void,AristoError] =
  ## Delete the account leaf entry addressed by the argument `path`. If this
  ## leaf entry referres to a storage tree, this one will be deleted as well.
  ##
  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return err(DelPathNotFound)
    return err(error)
  let
    stoID = accHike.legs[^1].wp.vtx.lData.stoID

  # Delete storage tree if present
  if stoID.isValid:
    ? db.delStoTreeImpl((stoID.vid, stoID.vid), accPath)

  let otherLeaf = ?db.deleteImpl(accHike)

  db.layersPutAccLeaf(accPath, nil)

  if otherLeaf.isValid:
    db.layersPutAccLeaf(
      Hash256(data: getBytes(NibblesBuf.fromBytes(accPath.data).replaceSuffix(otherLeaf.pfx))),
      otherLeaf)

  ok()

proc deleteGenericData*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[bool,AristoError] =
  ## Delete the leaf data entry addressed by the argument `path`.  The MPT
  ## sub-tree the leaf data entry is subsumed under is passed as argument
  ## `root` which must be greater than `VertexID(1)` and smaller than
  ## `LEAST_FREE_VID`.
  ##
  ## The return value is `true` if the argument `path` deleted was the last
  ## one and the tree does not exist anymore.
  ##
  # Verify that `root` is neither an accounts tree nor a strorage tree.
  if not root.isValid:
    return err(DelRootVidMissing)
  elif root == VertexID(1):
    return err(DelAccRootNotAccepted)
  elif LEAST_FREE_VID <= root.distinctBase:
    return err(DelStoRootNotAccepted)

  var hike: Hike
  path.hikeUp(root, db, Opt.none(VertexRef), hike).isOkOr:
    if error[1] in HikeAcceptableStopsNotFound:
      return err(DelPathNotFound)
    return err(error[1])

  discard ?db.deleteImpl(hike)

  ok(not db.getVtx((root, root)).isValid)

proc deleteGenericTree*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # Root vertex
      ): Result[void,AristoError] =
  ## Variant of `deleteGenericData()` for purging the whole MPT sub-tree.
  ##
  # Verify that `root` is neither an accounts tree nor a strorage tree.
  if not root.isValid:
    return err(DelRootVidMissing)
  elif root == VertexID(1):
    return err(DelAccRootNotAccepted)
  elif LEAST_FREE_VID <= root.distinctBase:
    return err(DelStoRootNotAccepted)

  db.delSubTreeImpl root

proc deleteStorageData*(
    db: AristoDbRef;
    accPath: Hash256;          # Implies storage data tree
    stoPath: Hash256;
      ): Result[bool,AristoError] =
  ## For a given account argument `accPath`, this function deletes the
  ## argument `stoPath` from the associated storage tree (if any, at all.) If
  ## the if the argument `stoPath` deleted was the last one on the storage tree,
  ## account leaf referred to by `accPath` will be updated so that it will
  ## not refer to a storage tree anymore. In the latter case only the function
  ## will return `true`.
  ##

  let
    mixPath = mixUp(accPath, stoPath)
    stoLeaf = db.cachedStoLeaf(mixPath)

  if stoLeaf == Opt.some(nil):
    return err(DelPathNotFound)

  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return err(DelStoAccMissing)
    return err(error)

  let
    wpAcc = accHike.legs[^1].wp
    stoID = wpAcc.vtx.lData.stoID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  let stoNibbles = NibblesBuf.fromBytes(stoPath.data)
  var stoHike: Hike
  stoNibbles.hikeUp(stoID.vid, db, stoLeaf, stoHike).isOkOr:
    if error[1] in HikeAcceptableStopsNotFound:
      return err(DelPathNotFound)
    return err(error[1])

  # Mark account path Merkle keys for update
  db.layersResKeys accHike

  let otherLeaf = ?db.deleteImpl(stoHike)
  db.layersPutStoLeaf(mixPath, nil)

  if otherLeaf.isValid:
    let leafMixPath = mixUp(
      accPath,
      Hash256(data: getBytes(stoNibbles.replaceSuffix(otherLeaf.pfx))))
    db.layersPutStoLeaf(leafMixPath, otherLeaf)

  # If there was only one item (that got deleted), update the account as well
  if stoHike.legs.len > 1:
    return ok(false)

  # De-register the deleted storage tree from the account record
  let leaf = wpAcc.vtx.dup           # Dup on modify
  leaf.lData.stoID.isValid = false
  db.layersPutAccLeaf(accPath, leaf)
  db.layersPutVtx((accHike.root, wpAcc.vid), leaf)
  ok(true)

proc deleteStorageTree*(
    db: AristoDbRef;                   # Database, top layer
    accPath: Hash256;          # Implies storage data tree
      ): Result[void,AristoError] =
  ## Variant of `deleteStorageData()` for purging the whole storage tree
  ## associated to the account argument `accPath`.
  ##
  var accHike: Hike
  db.fetchAccountHike(accPath, accHike).isOkOr:
    if error == FetchAccInaccessible:
      return err(DelStoAccMissing)
    return err(error)

  let
    wpAcc = accHike.legs[^1].wp
    stoID = wpAcc.vtx.lData.stoID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  # Mark account path Merkle keys for update
  db.layersResKeys accHike

  ? db.delStoTreeImpl((stoID.vid, stoID.vid), accPath)

  # De-register the deleted storage tree from the accounts record
  let leaf = wpAcc.vtx.dup             # Dup on modify
  leaf.lData.stoID.isValid = false
  db.layersPutAccLeaf(accPath, leaf)
  db.layersPutVtx((accHike.root, wpAcc.vid), leaf)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
