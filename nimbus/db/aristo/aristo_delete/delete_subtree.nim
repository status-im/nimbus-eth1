# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_layers],
  ./delete_helpers

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc collectStoTreeLazily(
  db: AristoDbRef;                     # Database, top layer
  rvid: RootedVertexID;                # Root vertex
  accPath: Hash256;                    # Accounts cache designator
  stoPath: NibblesBuf;                 # Current storage path
    ): Result[void,AristoError] =
  ## Collect vertex/vid and delete cache entries.
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    for i in 0..15:
      if vtx.bVid[i].isValid:
        ? db.collectStoTreeLazily(
          (rvid.root, vtx.bVid[i]), accPath,
          stoPath & vtx.ePfx & NibblesBuf.nibble(byte i))

  of Leaf:
    let stoPath = Hash256(data: (stoPath & vtx.lPfx).getBytes())
    db.layersPutStoLeaf(AccountKey.mixUp(accPath, stoPath), nil)

  # There is no useful approach avoiding to walk the whole tree for updating
  # the storage data access cache.
  #
  # The alternative of stopping here and clearing the whole cache did degrade
  # performance significantly in some tests on mainnet when importing `era1`.
  #
  # The cache it was seen
  # * filled up to maximum size most of the time
  # * at the same time having no `stoPath` hit at all (so there was nothing
  #   to be cleared.)
  #
  ok()


proc disposeOfSubTree(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
      ) =
  ## Evaluate results from `collectSubTreeLazyImpl()` or ftom
  ## `collectStoTreeLazyImpl)`.
  ##
  let vtx = db.getVtxRc(rvid).value[0]
  if vtx.vType == Branch:
    for n in 0..15:
      if vtx.bVid[n].isValid:
        db.top.delTree.add (rvid.root,vtx.bVid[n])

  # Delete top of tree now.
  db.disposeOfVtx(rvid)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delSubTreeImpl*(
    db: AristoDbRef;                   # Database, top layer
    root: VertexID;                    # Root vertex
      ): Result[void,AristoError] =
  ## Delete all the `subRoots`if there are a few, only. Otherwise
  ## mark it for deleting later.
  discard db.getVtxRc((root,root)).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  db.disposeOfSubTree((root,root))

  ok()


proc delStoTreeImpl*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    accPath: Hash256;
      ): Result[void,AristoError] =
  ## Collect vertex/vid and cache entry.
  discard db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  ? db.collectStoTreeLazily(rvid, accPath, NibblesBuf())

  db.disposeOfSubTree(rvid)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
