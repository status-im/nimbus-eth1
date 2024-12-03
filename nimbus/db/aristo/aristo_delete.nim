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
  ./aristo_delete/delete_subtree,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike, aristo_layers]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: VertexRef, removed: int8): Result[int8,void] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1'i8
  for n in 0'i8 .. 15'i8:
    if n == removed:
      continue

    if vtx.bVid(uint8 n).isValid:
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
    T: type
      ): Result[Opt[T],AristoError] =
  ## Removes the last node in the hike and returns the updated leaf in case
  ## a branch collapsed

  # Remove leaf entry
  let lf = hike.legs[^1].wp
  if lf.vtx.vType != Leaf:
    return err(DelLeafExpexted)

  db.layersResVtx((hike.root, lf.vid))

  if hike.legs.len == 1:
    # This was the last node in the trie, meaning we don't have any branches or
    # leaves to update
    return ok(default(Opt[T]))

  if hike.legs[^2].wp.vtx.vType != Branch:
    return err(DelBranchExpexted)

  # Get current `Branch` vertex `br`
  let
    br = hike.legs[^2].wp
    nbl = br.vtx.branchStillNeeded(hike.legs[^2].nibble).valueOr:
      return err(DelBranchWithoutRefs)

  # Clear all Merkle hash keys up to the root key
  for n in 0 .. hike.legs.len - 2:
    let wp = hike.legs[n].wp
    db.layersResKey((hike.root, wp.vid), wp.vtx)

  if 0 <= nbl:
    # Branch has only one entry - move that entry to where the branch was and
    # update its path

    # Get child vertex (there must be one after a `Branch` node)
    let
      vid = br.vtx.bVid(uint8 nbl)
      nxt = db.getVtx (hike.root, vid)
    if not nxt.isValid:
      return err(DelVidStaleVtx)

    db.layersResVtx((hike.root, vid))

    let vtx =
      case nxt.vType
      of Empty: raiseAssert "unexpected empty vtx"
      of Leaf:
        VertexRef(
          vType: Leaf,
          pfx:  br.vtx.pfx & NibblesBuf.nibble(nbl.byte) & nxt.pfx,
          lData: nxt.lData)

      of Branch:
        VertexRef(
          vType: Branch,
          pfx:  br.vtx.pfx & NibblesBuf.nibble(nbl.byte) & nxt.pfx,
          startVid: nxt.startVid,
          used: nxt.used)

    # Put the new vertex at the id of the obsolete branch
    db.layersPutVtx((hike.root, br.vid), vtx)

    if vtx.vType == Leaf:
      ok(Opt.some(vtx.to(T)))
    else:
      ok(Opt.none(T))
  else:
    # Clear the removed leaf from the branch (that still contains other children)
    var brDup = br.vtx.dup
    discard brDup.setUsed(uint8 hike.legs[^2].nibble, false)
    db.layersPutVtx((hike.root, br.vid), brDup)

    ok(Opt.none(T))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deleteAccountRecord*(
    db: AristoDbRef;
    accPath: Hash32;
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

  let otherLeaf = ?db.deleteImpl(accHike, AccountLeaf)

  db.layersPutAccLeaf(accPath, default(Opt[AccountLeaf]))

  if otherLeaf.isSome:
    db.layersPutAccLeaf(
      Hash32(getBytes(NibblesBuf.fromBytes(accPath.data).replaceSuffix(otherLeaf[].pfx))),
      otherLeaf)

  ok()

proc deleteStorageData*(
    db: AristoDbRef;
    accPath: Hash32;          # Implies storage data tree
    stoPath: Hash32;
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

  if stoLeaf == Opt.some(default(Opt[StoLeaf])):
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

  let otherLeaf = ?db.deleteImpl(stoHike, StoLeaf)
  db.layersPutStoLeaf(mixPath, default(Opt[StoLeaf]))

  if otherLeaf.isSome:
    let leafMixPath = mixUp(
      accPath,
      Hash32(getBytes(stoNibbles.replaceSuffix(otherLeaf[].pfx))))
    db.layersPutStoLeaf(leafMixPath, otherLeaf)

  # If there was only one item (that got deleted), update the account as well
  if stoHike.legs.len > 1:
    return ok(false)

  # De-register the deleted storage tree from the account record
  var leaf = wpAcc.vtx.dup           # Dup on modify
  leaf.lData.stoID.isValid = false
  db.layersPutAccLeaf(accPath, Opt.some(leaf.to(AccountLeaf)))
  db.layersPutVtx((accHike.root, wpAcc.vid), leaf)
  ok(true)

proc deleteStorageTree*(
    db: AristoDbRef;                   # Database, top layer
    accPath: Hash32;                   # Implies storage data tree
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
  var leaf = wpAcc.vtx.dup             # Dup on modify
  leaf.lData.stoID.isValid = false
  db.layersPutAccLeaf(accPath, Opt.some(leaf.to(AccountLeaf)))
  db.layersPutVtx((accHike.root, wpAcc.vid), leaf)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
