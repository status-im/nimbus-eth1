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
  eth/common/hashes,
  ".."/[aristo_desc, aristo_get, aristo_layers]

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

proc delSubTreeNow(
    db: AristoTxRef;
    rvid: RootedVertexID;
      ): Result[void,AristoError] =
  ## Delete sub-tree now
  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  if vtx.vType == Branch:
    for _, subvid in vtx.pairs():
      ? db.delSubTreeNow((rvid.root, subvid))

  db.layersResVtx(rvid)

  ok()


proc delStoTreeNow(
  db: AristoTxRef;                   # Database, top layer
  rvid: RootedVertexID;              # Root vertex
  accPath: Hash32;                   # Accounts cache designator
  stoPath: NibblesBuf;               # Current storage path
    ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.

  let (vtx, _) = db.getVtxRc(rvid).valueOr:
    if error == GetVtxNotFound:
      return ok()
    return err(error)

  case vtx.vType
  of Branch:
    for n, subvid in vtx.pairs():
      ? db.delStoTreeNow(
        (rvid.root, subvid), accPath,
        stoPath & vtx.pfx & NibblesBuf.nibble(n))

  of Leaf:
    let stoPath = Hash32((stoPath & vtx.pfx).getBytes())
    db.layersPutStoLeaf(mixUp(accPath, stoPath), nil)

  db.layersResVtx(rvid)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delSubTreeImpl*(
    db: AristoTxRef;
    root: VertexID;
      ): Result[void,AristoError] =
  db.delSubTreeNow (root,root)


proc delStoTreeImpl*(
    db: AristoTxRef;                   # Database, top layer
    rvid: RootedVertexID;              # Root vertex
    accPath: Hash32;
      ): Result[void,AristoError] =
  ## Implementation of *delete* sub-trie.
  db.delStoTreeNow(rvid, accPath, NibblesBuf())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
