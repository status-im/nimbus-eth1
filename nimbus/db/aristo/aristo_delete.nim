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
## Delete by `Hike` type chain of vertices.

{.push raises: [].}

import
  std/typetraits,
  eth/common,
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike, aristo_layers,
       aristo_utils, aristo_vid]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: VertexRef): Result[int,void] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1
  for n in 0 .. 15:
    if vtx.bVid[n].isValid:
      if 0 <= nibble:
        return ok(-1)
      nibble = n
  if 0 <= nibble:
    return ok(nibble)
  # Oops, degenerated branch node
  err()

# -----------

proc disposeOfVtx(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Vertex ID to clear
      ) =
  # Remove entry
  db.layersResVtx(rvid)
  db.layersResKey(rvid)
  db.vidDispose rvid.vid               # Recycle ID

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc delSubTreeImpl(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # Root vertex
      ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.
  var
    dispose = @[root]
    rootVtx = db.getVtxRc((root, root)).valueOr:
      if error == GetVtxNotFound:
        return ok()
      return err(error)
    follow = @[rootVtx]

  # Collect list of nodes to delete
  while 0 < follow.len:
    var redo: seq[VertexRef]
    for vtx in follow:
      for vid in vtx.subVids:
        # Exiting here leaves the tree as-is
        let vtx = ? db.getVtxRc((root, vid))
        redo.add vtx
        dispose.add vid
    redo.swap follow

  # Mark collected vertices to be deleted
  for vid in dispose:
    db.disposeOfVtx((root, vid))

  ok()

proc delStoTreeImpl(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;                    # Root vertex
    accPath: Hash256;
    stoPath: NibblesBuf;
      ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.

  let vtx = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    for i in 0..15:
      if vtx.bVid[i].isValid:
        ? db.delStoTreeImpl(
          (rvid.root, vtx.bVid[i]), accPath,
          stoPath & vtx.ePfx & NibblesBuf.nibble(byte i))

  of Leaf:
    let stoPath = Hash256(data: (stoPath & vtx.lPfx).getBytes())
    db.layersPutStoLeaf(AccountKey.mixUp(accPath, stoPath), nil)

  db.disposeOfVtx(rvid)

  ok()

proc deleteImpl(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
      ): Result[void,AristoError] =
  ## Implementation of *delete* functionality.

  # Remove leaf entry
  let lf =  hike.legs[^1].wp
  if lf.vtx.vType != Leaf:
    return err(DelLeafExpexted)

  db.disposeOfVtx((hike.root, lf.vid))

  if 1 < hike.legs.len:
    # Get current `Branch` vertex `br`
    let br = block:
      var wp = hike.legs[^2].wp
      wp.vtx = wp.vtx.dup # make sure that layers are not impliciteley modified
      wp
    if br.vtx.vType != Branch:
      return err(DelBranchExpexted)

    # Unlink child vertex from structural table
    br.vtx.bVid[hike.legs[^2].nibble] = VertexID(0)
    db.layersPutVtx((hike.root, br.vid), br.vtx)

    # Clear all Merkle hash keys up to the root key
    for n in 0 .. hike.legs.len - 2:
      let vid = hike.legs[n].wp.vid
      db.layersResKey((hike.root, vid))

    let nbl = block:
      let rc = br.vtx.branchStillNeeded()
      if rc.isErr:
        return err(DelBranchWithoutRefs)
      rc.value

    if 0 <= nbl:
      # Branch has only one entry - convert it to a leaf or join with parent

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
            lPfx:  br.vtx.ePfx & NibblesBuf.nibble(nbl.byte) & nxt.lPfx,
            lData: nxt.lData)
        of Branch:
          VertexRef(
            vType: Branch,
            ePfx:  br.vtx.ePfx & NibblesBuf.nibble(nbl.byte) & nxt.ePfx,
            bVid: nxt.bVid)

      # Put the new vertex at the id of the obsolete branch
      db.layersPutVtx((hike.root, br.vid), vtx)

  ok()

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
  let
    hike = accPath.hikeUp(VertexID(1), db).valueOr:
      if error[1] in HikeAcceptableStopsNotFound:
        return err(DelPathNotFound)
      return err(error[1])
    stoID = hike.legs[^1].wp.vtx.lData.stoID

  # Delete storage tree if present
  if stoID.isValid:
    ? db.delStoTreeImpl((stoID, stoID), accPath, NibblesBuf())

  ?db.deleteImpl(hike)

  db.layersPutAccLeaf(accPath, nil)

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

  let hike = path.hikeUp(root, db).valueOr:
    if error[1] in HikeAcceptableStopsNotFound:
      return err(DelPathNotFound)
    return err(error[1])

  ?db.deleteImpl(hike)

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
    accHike = db.fetchAccountHike(accPath).valueOr:
      if error == FetchAccInaccessible:
        return err(DelStoAccMissing)
      return err(error)
    wpAcc = accHike.legs[^1].wp
    stoID = wpAcc.vtx.lData.stoID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  let stoHike = stoPath.hikeUp(stoID, db).valueOr:
    if error[1] in HikeAcceptableStopsNotFound:
      return err(DelPathNotFound)
    return err(error[1])

  # Mark account path Merkle keys for update
  db.updateAccountForHasher accHike

  ?db.deleteImpl(stoHike)

  db.layersPutStoLeaf(AccountKey.mixUp(accPath, stoPath), nil)

  # Make sure that an account leaf has no dangling sub-trie
  if db.getVtx((stoID, stoID)).isValid:
    return ok(false)

  # De-register the deleted storage tree from the account record
  let leaf = wpAcc.vtx.dup           # Dup on modify
  leaf.lData.stoID = VertexID(0)
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
  let
    accHike = db.fetchAccountHike(accPath).valueOr:
      if error == FetchAccInaccessible:
        return err(DelStoAccMissing)
      return err(error)
    wpAcc = accHike.legs[^1].wp
    stoID = wpAcc.vtx.lData.stoID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  # Mark account path Merkle keys for update
  db.updateAccountForHasher accHike

  ? db.delStoTreeImpl((stoID, stoID), accPath, NibblesBuf())

  # De-register the deleted storage tree from the accounts record
  let leaf = wpAcc.vtx.dup             # Dup on modify
  leaf.lData.stoID = VertexID(0)
  db.layersPutAccLeaf(accPath, leaf)
  db.layersPutVtx((accHike.root, wpAcc.vid), leaf)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
