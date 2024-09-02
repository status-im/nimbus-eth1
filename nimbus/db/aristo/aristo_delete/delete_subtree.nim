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
  ".."/[aristo_desc, aristo_get, aristo_layers],
  ./delete_helpers

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc delSubTreeNow(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ): Result[void,AristoError] =
  ## Delete sub-tree now
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  if vtx.vType == Branch:
    for n in 0..15:
      if vtx.bVid[n].isValid:
        ? db.delSubTreeNow((rvid.root,vtx.bVid[n]))

  db.disposeOfVtx(rvid)

  ok()


proc delStoTreeNow(
  db: AristoDbRef;                   # Database, top layer
  rvid: RootedVertexID;              # Root vertex
  accPath: Hash256;                  # Accounts cache designator
  stoPath: NibblesBuf;               # Current storage path
    ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.

  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    for i in 0..15:
      if vtx.bVid[i].isValid:
        ? db.delStoTreeNow(
          (rvid.root, vtx.bVid[i]), accPath,
          stoPath & vtx.ePfx & NibblesBuf.nibble(byte i))

  of Leaf:
    let stoPath = Hash256(data: (stoPath & vtx.lPfx).getBytes())
    db.layersPutStoLeaf(AccountKey.mixUp(accPath, stoPath), nil)

  db.disposeOfVtx(rvid)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delSubTreeImpl*(
    db: AristoDbRef;
    root: VertexID;
      ): Result[void,AristoError] =
  db.delSubTreeNow (root,root)


proc delStoTreeImpl*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    accPath: Hash256;
      ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.
  db.delStoTreeNow(rvid, accPath, NibblesBuf())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
