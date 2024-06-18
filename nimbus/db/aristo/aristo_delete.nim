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
  std/[sets, typetraits],
  eth/[common, trie/nibbles],
  results,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers, aristo_path,
       aristo_utils, aristo_vid]

type
  SaveToVaeVidFn =
    proc(err: AristoError): (VertexID,AristoError) {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

func toVae(err: AristoError): (VertexID,AristoError) =
  ## Map single error to error pair with dummy vertex
  (VertexID(0),err)

func toVae(vid: VertexID): SaveToVaeVidFn =
  ## Map single error to error pair with argument vertex
  result =
    proc(err: AristoError): (VertexID,AristoError) =
      return (vid,err)

func toVae(err: (VertexID,AristoError,Hike)): (VertexID,AristoError) =
  (err[0], err[1])

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
    root: VertexID;
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  # Remove entry
  db.layersResVtx(root, vid)
  db.layersResKey(root, vid)
  db.vidDispose vid                    # Recycle ID

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc collapseBranch(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Applicable link for `Branch` vertex
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   current            | becomes             | condition
  ##                      |                     |
  ##   ^3     ^2          |  ^3     ^2          |
  ##   -------------------+---------------------+------------------
  ##   Branch <br> Branch | Branch <ext> Branch | 2 < legs.len  (1)
  ##   Ext    <br> Branch | <ext>        Branch | 2 < legs.len  (2)
  ##          <br> Branch |        <ext> Branch | legs.len == 2 (3)
  ##
  ## Depending on whether the parent `par` is an extension, merge `br` into
  ## `par`. Otherwise replace `br` by an extension.
  ##
  let br = hike.legs[^2].wp

  var xt = VidVtxPair(                                   # Rewrite `br`
    vid: br.vid,
    vtx: VertexRef(
      vType: Extension,
      ePfx:  @[nibble].initNibbleRange.slice(1),
      eVid:  br.vtx.bVid[nibble]))

  if 2 < hike.legs.len:                                  # (1) or (2)
    let par = hike.legs[^3].wp
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `br` (use `xt` as-is)
      discard

    of Extension:                                        # (2)
      # Merge `br` into ^3 (update `xt`)
      db.disposeOfVtx(hike.root, xt.vid)
      xt.vid = par.vid
      xt.vtx.ePfx = par.vtx.ePfx & xt.vtx.ePfx

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (3)
    # Replace `br` (use `xt` as-is)
    discard

  db.layersPutVtx(hike.root, xt.vid, xt.vtx)
  ok()


proc collapseExt(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Link for `Branch` vertex `^2`
    vtx: VertexRef;                    # Follow up extension vertex (nibble)
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   ^3       ^2   `vtx` |   ^3      ^2    |
  ##   --------------------+-----------------------+------------------
  ##   Branch  <br>   Ext  |  Branch  <ext>  | 2 < legs.len  (1)
  ##   Ext     <br>   Ext  |  <ext>          | 2 < legs.len  (2)
  ##           <br>   Ext  |          <ext>  | legs.len == 2 (3)
  ##
  ## Merge `vtx` into `br` and unlink `vtx`.
  ##
  let br = hike.legs[^2].wp

  var xt = VidVtxPair(                                   # Merge `vtx` into `br`
    vid: br.vid,
    vtx: VertexRef(
      vType: Extension,
      ePfx:  @[nibble].initNibbleRange.slice(1) & vtx.ePfx,
      eVid:  vtx.eVid))
  db.disposeOfVtx(hike.root, br.vtx.bVid[nibble])        # `vtx` is obsolete now

  if 2 < hike.legs.len:                                  # (1) or (2)
    let par = hike.legs[^3].wp
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `br` by `^2 & vtx` (use `xt` as-is)
      discard

    of Extension:                                        # (2)
      # Replace ^3 by `^3 & ^2 & vtx` (update `xt`)
      db.disposeOfVtx(hike.root, xt.vid)
      xt.vid = par.vid
      xt.vtx.ePfx = par.vtx.ePfx & xt.vtx.ePfx

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (3)
    # Replace ^2 by `^2 & vtx` (use `xt` as-is)
    discard

  db.layersPutVtx(hike.root, xt.vid, xt.vtx)
  ok()


proc collapseLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Link for `Branch` vertex `^2`
    vtx: VertexRef;                    # Follow up leaf vertex (from nibble)
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   current                  | becomes                    | condition
  ##                            |                            |
  ##    ^4     ^3     ^2  `vtx` | ^4      ^3     ^2          |
  ##   -------------------------+----------------------------+------------------
  ##   ..     Branch <br>  Leaf | ..     Branch       <Leaf> | 2 < legs.len  (1)
  ##   Branch Ext    <br>  Leaf | Branch              <Leaf> | 3 < legs.len  (2)
  ##          Ext    <br>  Leaf |              <Leaf>        | legs.len == 3 (3)
  ##                 <br>  Leaf |              <Leaf>        | legs.len == 2 (4)
  ##
  ## Merge `<br>` and `Leaf` replacing one and removing the other.
  ##
  let br = hike.legs[^2].wp

  var lf = VidVtxPair(                                   # Merge `br` into `vtx`
    vid: br.vtx.bVid[nibble],
    vtx: VertexRef(
      vType: Leaf,
      lPfx:  @[nibble].initNibbleRange.slice(1) & vtx.lPfx,
      lData: vtx.lData))
  db.layersResKey(hike.root, lf.vid)                     # `vtx` was modified

  if 2 < hike.legs.len:                                  # (1), (2), or (3)
    db.disposeOfVtx(hike.root, br.vid)                   # `br` is obsolete now
    # Merge `br` into the leaf `vtx` and unlink `br`.
    let par = hike.legs[^3].wp.dup                       # Writable vertex
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `vtx` by `^2 & vtx` (use `lf` as-is)
      par.vtx.bVid[hike.legs[^3].nibble] = lf.vid
      db.layersPutVtx(hike.root, par.vid, par.vtx)
      db.layersPutVtx(hike.root, lf.vid, lf.vtx)
      return ok()

    of Extension:                                        # (2) or (3)
      # Merge `^3` into `lf` but keep the leaf vertex ID unchanged. This
      # can avoid some extra updates.
      lf.vtx.lPfx = par.vtx.ePfx & lf.vtx.lPfx

      if 3 < hike.legs.len:                              # (2)
        # Grandparent exists
        let gpr = hike.legs[^4].wp.dup                   # Writable vertex
        if gpr.vtx.vType != Branch:
          return err((gpr.vid,DelBranchExpexted))
        db.disposeOfVtx(hike.root, par.vid)              # `par` is obsolete now
        gpr.vtx.bVid[hike.legs[^4].nibble] = lf.vid
        db.layersPutVtx(hike.root, gpr.vid, gpr.vtx)
        db.layersPutVtx(hike.root, lf.vid, lf.vtx)
        return ok()

      # No grandparent, so ^3 is root vertex             # (3)
      db.layersPutVtx(hike.root, par.vid, lf.vtx)
      # Continue below

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (4)
    # Replace ^2 by `^2 & vtx` (use `lf` as-is)          # `br` is root vertex
    db.layersResKey(hike.root, br.vid)                   # root was changed
    db.layersPutVtx(hike.root, br.vid, lf.vtx)
    # Continue below

  # Clean up stale leaf vertex which has moved to root position
  db.disposeOfVtx(hike.root, lf.vid)

  ok()

# -------------------------

proc delSubTreeImpl(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # Root vertex
    accPath: PathID;                   # Needed for real storage tries
    ignoreAccPathOk = false;           # Temporary, will go away
      ): Result[void,(VertexID,AristoError)] =
  ## Implementation of *delete* sub-trie.
  let wp = block:
    if root.distinctBase < LEAST_FREE_VID:
      if not root.isValid:
        return err((root,DelSubTreeVoidRoot))
      if root == VertexID(1):
        return err((root,DelSubTreeAccRoot))
      VidVtxPair()
    elif ignoreAccPathOk:
      VidVtxPair()
    else:
      let rc = db.registerAccount(root, accPath)
      if rc.isErr:
        return err((root,rc.error))
      else:
        rc.value
  var
    dispose = @[root]
    rootVtx = db.getVtxRc(root).valueOr:
      if error == GetVtxNotFound:
        return ok()
      return err((root,error))
    follow = @[rootVtx]

  # Collect list of nodes to delete
  while 0 < follow.len:
    var redo: seq[VertexRef]
    for vtx in follow:
      for vid in vtx.subVids:
        # Exiting here leaves the tree as-is
        let vtx = ? db.getVtxRc(vid).mapErr toVae(vid)
        redo.add vtx
        dispose.add vid
    redo.swap follow

  # Mark nodes deleted
  for vid in dispose:
    db.disposeOfVtx(root, vid)

  # Make sure that an account leaf has no dangling sub-trie
  if wp.vid.isValid:
    let leaf = wp.vtx.dup # Dup on modify
    leaf.lData.account.storageID = VertexID(0)
    db.layersPutVtx(VertexID(1), wp.vid, leaf)
    db.layersResKey(VertexID(1), wp.vid)

  ok()


proc deleteImpl(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    lty: LeafTie;                      # `Patricia Trie` path root-to-leaf
    accPath: PathID;                   # Needed for accounts payload
    ignoreStoID = false;               # Temporary, will go away
      ): Result[bool,(VertexID,AristoError)] =
  ## Implementation of *delete* functionality.

  let wp = block:
    if lty.root.distinctBase < LEAST_FREE_VID:
      VidVtxPair()
    elif ignoreStoID:
      VidVtxPair()
    else:
      let rc = db.registerAccount(lty.root, accPath)
      if rc.isErr:
        return err((lty.root,rc.error))
      else:
        rc.value

  # Remove leaf entry on the top
  let lf =  hike.legs[^1].wp
  if lf.vtx.vType != Leaf:
    return err((lf.vid,DelLeafExpexted))
  if lf.vid in db.pPrf:
    return err((lf.vid, DelLeafLocked))

  # Verify that there is no dangling storage trie
  if not ignoreStoID:
    let data = lf.vtx.lData
    if data.pType == AccountData:
      let vid = data.account.storageID
      if vid.isValid and db.getVtx(vid).isValid:
        return err((vid,DelDanglingStoTrie))

  db.disposeOfVtx(hike.root, lf.vid)

  if 1 < hike.legs.len:
    # Get current `Branch` vertex `br`
    let br = block:
      var wp = hike.legs[^2].wp
      wp.vtx = wp.vtx.dup # make sure that layers are not impliciteley modified
      wp
    if br.vtx.vType != Branch:
      return err((br.vid,DelBranchExpexted))

    # Unlink child vertex from structural table
    br.vtx.bVid[hike.legs[^2].nibble] = VertexID(0)
    db.layersPutVtx(hike.root, br.vid, br.vtx)

    # Clear all keys up to the root key
    for n in 0 .. hike.legs.len - 2:
      let vid = hike.legs[n].wp.vid
      if vid in db.top.final.pPrf:
        return err((vid, DelBranchLocked))
      db.layersResKey(hike.root, vid)

    let nibble = block:
      let rc = br.vtx.branchStillNeeded()
      if rc.isErr:
        return err((br.vid,DelBranchWithoutRefs))
      rc.value

    # Convert to `Extension` or `Leaf` vertex
    if 0 <= nibble:
      # Get child vertex (there must be one after a `Branch` node)
      let nxt = block:
        let vid = br.vtx.bVid[nibble]
        VidVtxPair(vid: vid, vtx: db.getVtx vid)
      if not nxt.vtx.isValid:
        return err((nxt.vid, DelVidStaleVtx))

      # Collapse `Branch` vertex `br` depending on `nxt` vertex type
      case nxt.vtx.vType:
      of Branch:
        ? db.collapseBranch(hike, nibble.byte)
      of Extension:
        ? db.collapseExt(hike, nibble.byte, nxt.vtx)
      of Leaf:
        ? db.collapseLeaf(hike, nibble.byte, nxt.vtx)

  let emptySubTreeOk = not db.getVtx(hike.root).isValid

  # Make sure that an account leaf has no dangling sub-trie
  if emptySubTreeOk and wp.vid.isValid:
    let leaf = wp.vtx.dup # Dup on modify
    leaf.lData.account.storageID = VertexID(0)
    db.layersPutVtx(VertexID(1), wp.vid, leaf)
    db.layersResKey(VertexID(1), wp.vid)

  ok(emptySubTreeOk)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deleteAccountPayload*(
    db: AristoDbRef;
    path: openArray[byte];
      ): Result[void,AristoError] =
  ## Delete the account leaf entry addressed by the argument `path`. If this
  ## leaf entry referres to a storage tree, this one will be deleted as well.
  ##
  let
    hike = path.initNibbleRange.hikeUp(VertexID(1), db).valueOr:
      if error[1] in HikeAcceptableStopsNotFound:
        return err(DelPathNotFound)
      return err(error[1])
    lty = LeafTie(root: VertexID(1), path: ? path.pathToTag())
    stoID = hike.legs[^1].wp.vtx.lData.account.storageID

  # Delete storage tree if present
  if stoID.isValid:
    db.delSubTreeImpl(stoID, lty.path).isOkOr:
      return err(error[1])

  discard db.deleteImpl(hike, lty, VOID_PATH_ID, ignoreStoID=true).valueOr:
    return err(error[1])

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

  let
    hike = path.initNibbleRange.hikeUp(root, db).valueOr:
      if error[1] in HikeAcceptableStopsNotFound:
        return err(DelPathNotFound)
      return err(error[1])
    lty = LeafTie(root: root, path: ? path.pathToTag())

  let emptyTreeOk = db.deleteImpl(
        hike, lty, VOID_PATH_ID, ignoreStoID=true).valueOr:
    return err(error[1])

  ok emptyTreeOk

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

  db.delSubTreeImpl(root, VOID_PATH_ID, ignoreAccPathOk=true).isOkOr:
    return err(error[1])
  ok()


proc deleteStorageData*(
    db: AristoDbRef;
    path: openArray[byte];
    accPath: PathID;                   # Needed for accounts payload
      ): Result[bool,AristoError] =
  ## For a given account argument `accPath`, this function deletes the
  ## argument `path` from the associated storage tree (if any, at all.) If
  ## the if the argument `path` deleted was the last one on the storage tree,
  ## account leaf referred to by `accPath` will be updated so that it will
  ## not refer to a storage tree anymore. In the latter case only the function
  ## will return `true`.
  ##
  let
    wpAcc = ? db.registerAccountForUpdate accPath
    stoID = wpAcc.vtx.lData.account.storageID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  let
    hike = path.initNibbleRange.hikeUp(stoID, db).valueOr:
      if error[1] in HikeAcceptableStopsNotFound:
        return err(DelPathNotFound)
      return err(error[1])

    lty = LeafTie(root: stoID, path: ? path.pathToTag())
    emptyTreeOk = db.deleteImpl(
      hike, lty, VOID_PATH_ID, ignoreStoID=true).valueOr:
        return err(error[1])

  # Make sure that an account leaf has no dangling sub-trie
  if emptyTreeOk:
    let leaf = wpAcc.vtx.dup           # Dup on modify
    leaf.lData.account.storageID = VertexID(0)
    db.layersPutVtx(VertexID(1), wpAcc.vid, leaf)
    db.layersResKey(VertexID(1), wpAcc.vid)

  ok emptyTreeOk

proc deleteStorageTree*(
    db: AristoDbRef;                   # Database, top layer
    accPath: PathID;                   # Needed for accounts payload
      ): Result[void,AristoError] =
  ## Variant of `deleteStorageData()` for purging the whole storage tree
  ## associated to the account argument `accPath`.
  ##
  let
    wpAcc = db.registerAccountForUpdate(accPath).valueOr:
      if error == UtilsAccInaccessible:
        return err(DelStoAccMissing)
      return err(error)
    stoID = wpAcc.vtx.lData.account.storageID

  if not stoID.isValid:
    return err(DelStoRootMissing)

  db.delSubTreeImpl(stoID, VOID_PATH_ID, ignoreAccPathOk=true).isOkOr:
    return err(error[1])

  # De-register the deleted tree from the accounts recotd
  let leaf = wpAcc.vtx.dup             # Dup on modify
  leaf.lData.account.storageID = VertexID(0)
  db.layersPutVtx(VertexID(1), wpAcc.vid, leaf)
  db.layersResKey(VertexID(1), wpAcc.vid)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
