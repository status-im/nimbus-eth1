# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  ./[aristo_desc, aristo_fetch, aristo_get, aristo_layers]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: BranchRef, removed: byte): Result[int8, AristoError] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1'i8
  for n in 0'u8 .. 15'u8:
    if n == removed:
      continue

    if vtx.bVid(n).isValid:
      if 0 <= nibble:
        return ok(-1)
      nibble = int8 n
  if 0 <= nibble:
    return ok(nibble)
  # Oops, degenerated branch node
  err(DelBranchWithoutRefs)

proc deleteStoTree(
    db: AristoTxRef, rvid: RootedVertexID, accPath: Hash32, stoPath: NibblesBuf
): Result[void, AristoError] =
  ## Implementation of *delete* sub-trie.

  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      if db.layersGetKeyOrVoid(rvid).isValid:
        # Subtrie known only by its hash (e.g. a stateless witness without it).
        # Drop the hash so that the vid can be reused for a fresh trie.
        db.layersResVtx(rvid)
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    let vtx = BranchRef(vtx)
    for n, subvid in vtx.pairs():
      ?db.deleteStoTree((rvid.root, subvid), accPath, stoPath & NibblesBuf.nibble(n))
  of BoundaryNode:
    discard # stateless only boundary node has no subvids to recurse into
  of ExtBranch:
    let vtx = ExtBranchRef(vtx)
    for n, subvid in vtx.pairs():
      ?db.deleteStoTree(
        (rvid.root, subvid), accPath, stoPath & vtx.pfx & NibblesBuf.nibble(n)
      )
  of StoLeaf:
    let vtx = StoLeafRef(vtx)
    let leafPath = (stoPath & vtx.pfx).to(Hash32)
    db.layersPutStoLeaf(mixUp(accPath, leafPath), nil)
  of AccLeaf:
    raiseAssert "Removing storage leaves only!"
  db.layersResVtx(rvid)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deleteLeaf*(db: AristoTxRef, hike: Hike): Result[VertexRef, AristoError] =
  ## Removes the last node in the hike and returns the updated node in case
  ## a branch collapsed

  # Remove leaf entry
  let lf = hike.legs[^1]
  if lf.vtx.vType notin Leaves:
    return err(DelLeafExpexted)

  db.layersResVtx((hike.root, lf.vid))

  if hike.legs.len == 1:
    # This was the last node in the trie, meaning we don't have any branches or
    # leaves to update
    return ok(nil)

  let br = hike.legs[^2]
  if br.vtx.vType notin Branches:
    return err(DelBranchExpexted)

  # Get current `Branch` vertex `br`
  let
    brVtx = BranchRef(br.vtx)
    nbl = ?brVtx.branchStillNeeded(br.nibble)

  # Clear keys that include `br` - `br` itself will be replaced below
  db.layersResKeys(hike, skip = 2)

  if 0 <= nbl:
    # Branch has only one entry - move that entry to where the branch was and
    # update its path

    # Get child vertex (there must be one after a `Branch` node)
    let
      vid = brVtx.bVid(nbl.byte)
      nxt = db.getVtx (hike.root, vid)
    if not nxt.isValid:
      # In stateless mode the surviving child may be a nil vertex boundary,
      # absent from the witness but with a known hash in kMap. Collapse the
      # branch into a BoundaryNode (prefix + boundary hash) so state root
      # computation stays correct.
      # In a full node this should be unreachable: every referenced child vid
      # should always have a non zero vertex.
      let childKey = db.layersGetKeyOrVoid((hike.root, vid))
      doAssert childKey.isValid,
        "nil surviving child without boundary hash, this is not a valid stateless boundary"
      let pfx =
        if brVtx.vType == Branch:
          NibblesBuf.nibble(nbl.byte)
        else:
          ExtBranchRef(brVtx).pfx & NibblesBuf.nibble(nbl.byte)
      let newExt = BoundaryNodeRef.init(pfx, childKey, unprovenCollapsep = true)
      db.layersPutVtx((hike.root, br.vid), newExt)
      db.unprovenCollapses.add((hike.root, br.vid))
      db.layersResVtx((hike.root, vid))
      return ok(VertexRef(newExt))

    db.layersResVtx((hike.root, vid))
    let
      pfx =
        if brVtx.vType == Branch:
          NibblesBuf.nibble(nbl.byte)
        else:
          ExtBranchRef(brVtx).pfx & NibblesBuf.nibble(nbl.byte)
      vtx =
        case nxt.vType
        of AccLeaf:
          let nxt = AccLeafRef(nxt)
          AccLeafRef.init(pfx & nxt.pfx, nxt.account, nxt.stoID, nxt.stoHint)
        of StoLeaf:
          let nxt = StoLeafRef(nxt)
          StoLeafRef.init(pfx & nxt.pfx, nxt.stoData)
        of Branch:
          let nxt = BranchRef(nxt)
          ExtBranchRef.init(pfx, nxt.startVid, nxt.used)
        of ExtBranch:
          let nxt = ExtBranchRef(nxt)
          ExtBranchRef.init(pfx & nxt.pfx, nxt.startVid, nxt.used)
        of BoundaryNode:
          let nxt = BoundaryNodeRef(nxt)
          if nxt.unprovenCollapse:
            db.unprovenCollapses.add((hike.root, br.vid))
          BoundaryNodeRef.init(pfx & nxt.pfx, nxt.childKey, nxt.unprovenCollapse)

    # Put the new vertex at the id of the obsolete branch
    db.layersPutVtx((hike.root, br.vid), vtx)

    if db.collectWitness:
      # The witness needs the pre-state node of the vertex the branch collapsed
      # onto, unless a later insert in the block restores the branch. Record
      # where the branch was, and its prefix length, to check that at the end.
      db.collapsedSiblings.add(((hike.root, vid), br.vid, uint8(brVtx.pfx.len)))

    ok(vtx)
  else:
    # Clear the removed leaf from the branch (that still contains other children)
    let brDup = db.layersUpdate((hike.root, br.vid), brVtx)
    discard brDup.setUsed(br.nibble, false)

    ok(nil)

proc deleteStoTree*(
    db: AristoTxRef, root: VertexID, accPath: Hash32
): Result[void, AristoError] =
  ## Implementation of *delete* sub-trie.
  db.deleteStoTree((root, root), accPath, NibblesBuf())

proc deleteAccount*(
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
  let stoID = AccLeafRef(accHike.legs[^1].vtx).stoID

  # Delete storage tree if present
  if stoID.isValid:
    ?db.deleteStoTree(stoID.vid, accPath)

  let otherVtx = ?db.deleteLeaf(accHike)

  db.layersPutAccLeaf(accPath, nil)

  if otherVtx.isValid and otherVtx.vType == AccLeaf:
    let sibAccPath = accPath.replaceSuffix(AccLeafRef(otherVtx).pfx)
    db.layersPutAccLeaf(sibAccPath, AccLeafRef(otherVtx))

  ok()

proc getCollapsedSiblings*(db: AristoTxRef): seq[RootedVertexID] =
  ## Collapsed siblings for witness generation. Persist runs per transaction,
  ## so a later insert in the block may restore a collapsed branch. The spec
  ## applies the block's writes at once and only needs the sibling if the
  ## final trie still lacks that branch.
  var res: seq[RootedVertexID]
  for (sibling, brVid, brPfxLen) in db.collapsedSiblings:
    let vtx = db.getVtx((sibling.root, brVid))
    if vtx.isValid and vtx.vType in Branches and vtx.pfx.len == int(brPfxLen):
      continue # restored by a later insert
    res.add(sibling)
  res

proc hasUnprovenCollapse*(db: AristoTxRef): bool =
  ## Stateless only: true if a branch that collapsed onto a child absent from
  ## the witness is still collapsed. The witness then lacks that child.
  for rvid in db.unprovenCollapses:
    let vtx = db.getVtx(rvid)
    if vtx.isValid and vtx.vType == BoundaryNode and
        BoundaryNodeRef(vtx).unprovenCollapse:
      return true
  false

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
