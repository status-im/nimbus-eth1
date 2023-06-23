# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
## Deleate by `Hike` type chain of vertices.

{.push raises: [].}

import
  std/[sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_path, aristo_vid]

logScope:
  topics = "aristo-delete"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: VertexRef): bool =
  for n in 0 .. 15:
    if vtx.bVid[n].isValid:
      return true

proc clearKey(
    db: AristoDb;                      # Database, top layer
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  let lbl = db.top.kMap.getOrVoid vid
  if lbl.isValid:
    db.top.kMap.del vid
    db.top.pAmk.del lbl
  elif db.getKeyBackend(vid).isOK:
    # Register for deleting on backend
    db.top.kMap[vid] = VOID_HASH_LABEL
    db.top.pAmk.del lbl

proc doneWith(
    db: AristoDb;                      # Database, top layer
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  # Remove entry
  db.vidDispose vid                    # Will be propagated to backend
  db.top.sTab.del vid
  db.clearKey vid


proc deleteImpl(
    hike: Hike;                        # Fully expanded path
    lty: LeafTie;                      # `Patricia Trie` path root-to-leaf
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Implementation of *delete* functionality.
  if hike.error != AristoError(0):
    if 0 < hike.legs.len:
      return err((hike.legs[^1].wp.vid,hike.error))
    return err((VertexID(0),hike.error))

  # doAssert 0 < hike.legs.len and hike.tail.len == 0 # as assured by `hikeUp()`

  var lf: VidVtxPair
  block:
    var inx = hike.legs.len - 1

    # Remove leaf entry on the top
    lf =  hike.legs[inx].wp
    if lf.vtx.vType != Leaf:
      return err((lf.vid,DelLeafExpexted))
    if lf.vid in db.top.pPrf:
      return err((lf.vid, DelLeafLocked))
    db.doneWith(lf.vid)
    inx.dec

    while 0 <= inx:
      # Unlink child vertex
      let br = hike.legs[inx].wp
      if br.vtx.vType != Branch:
        return err((br.vid,DelBranchExpexted))
      if br.vid in db.top.pPrf:
        return err((br.vid, DelBranchLocked))
      br.vtx.bVid[hike.legs[inx].nibble] = VertexID(0)
      db.top.sTab[br.vid] = br.vtx

      if br.vtx.branchStillNeeded:
        # Clear all keys up to the toot key
        db.clearKey(br.vid)
        while 0 < inx:
          inx.dec
          db.clearKey(hike.legs[inx].wp.vid)
        break

      # Remove this `Branch` entry
      db.doneWith(br.vid)
      inx.dec

      if inx < 0:
        break

      # There might be an optional `Extension` to remove
      let ext = hike.legs[inx].wp
      if ext.vtx.vType == Extension:
        if br.vid in db.top.pPrf:
          return err((ext.vid, DelExtLocked))
        db.doneWith(ext.vid)
        inx.dec

  # Delete leaf entry
  let rc = db.getVtxBackend lf.vid
  if rc.isErr and rc.error == GetVtxNotFound:
    # No need to keep it any longer
    db.top.lTab.del lty
  else:
    # To be recorded on change history
    db.top.lTab[lty] = VertexID(0)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delete*(
    hike: Hike;                        # Fully expanded chain of vertices
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Delete argument `hike` chain of vertices from the database
  # Need path in order to remove it from `lTab[]`
  let lky = block:
    let rc = hike.to(NibblesSeq).pathToTag()
    if rc.isErr:
      return err((VertexID(0),DelPathTagError))
    LeafTie(root: hike.root, path: rc.value)
  hike.deleteImpl(lky, db)

proc delete*(
    lty: LeafTie;                      # `Patricia Trie` path root-to-leaf
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Variant of `delete()`
  lty.hikeUp(db).deleteImpl(lty, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
