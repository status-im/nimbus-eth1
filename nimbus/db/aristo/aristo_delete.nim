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
  "."/[aristo_constants, aristo_desc, aristo_error, aristo_get, aristo_hike,
       aristo_path, aristo_vid]

logScope:
  topics = "aristo-delete"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc branchStillNeeded(vtx: VertexRef): bool =
  for n in 0 .. 15:
    if vtx.bVid[n] != VertexID(0):
      return true

proc clearKey(db: AristoDbRef; vid: VertexID) =
  let key = db.kMap.getOrDefault(vid, EMPTY_ROOT_KEY)
  if key != EMPTY_ROOT_KEY:
    db.kMap.del vid
    db.pAmk.del key

proc doneWith(db: AristoDbRef; vid: VertexID) =
  # Remove entry
  db.vidDispose vid
  db.sTab.del vid
  db.clearKey vid # Update Merkle hash


proc deleteImpl(
    hike: Hike;                        # Fully expanded path
    pathTag: NodeTag;                  # `Patricia Trie` path root-to-leaf
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Implementation of *delete* functionality.
  if hike.error != AristoError(0):
    if 0 < hike.legs.len:
      return err((hike.legs[^1].wp.vid,hike.error))
    return err((VertexID(0),hike.error))

  # doAssert 0 < hike.legs.len and hike.tail.len == 0 # as assured by `hikeUp()`
  var inx = hike.legs.len - 1

  # Remove leaf entry on the top
  let lf =  hike.legs[inx].wp
  if lf.vtx.vType != Leaf:
    return err((lf.vid,DelLeafExpexted))
  if lf.vid in db.pPrf:
    return err((lf.vid, DelLeafLocked))
  db.doneWith lf.vid
  inx.dec

  while 0 <= inx:
    # Unlink child node
    let br = hike.legs[inx].wp
    if br.vtx.vType != Branch:
      return err((br.vid,DelBranchExpexted))
    if br.vid in db.pPrf:
      return err((br.vid, DelBranchLocked))
    br.vtx.bVid[hike.legs[inx].nibble] = VertexID(0)

    if br.vtx.branchStillNeeded:
      db.clearKey br.vid
      break

    # Remove this `Branch` entry
    db.doneWith br.vid
    inx.dec

    if inx < 0:
      break

    # There might be an optional `Extension` to remove
    let ext = hike.legs[inx].wp
    if ext.vtx.vType == Extension:
      if br.vid in db.pPrf:
        return err((ext.vid, DelExtLocked))
      db.doneWith ext.vid
      inx.dec

  # Delete leaf entry
  db.lTab.del pathTag
  if db.lTab.len == 0:
    db.lRoot = VertexID(0)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delete*(
    hike: Hike;                        # Fully expanded chain of vertices
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Delete argument `hike` chain of vertices from the database
  # Need path in order to remove it from `lTab[]`
  let pathTag = block:
    let rc = hike.to(NibblesSeq).pathToTag()
    if rc.isErr:
      return err((VertexID(0),DelPathTagError))
    rc.value
  hike.deleteImpl(pathTag, db)

proc delete*(
    pathTag: NodeTag;                  # `Patricia Trie` path root-to-leaf
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Variant of `delete()`
  pathTag.hikeUp(db.lRoot, db).deleteImpl(pathTag, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
