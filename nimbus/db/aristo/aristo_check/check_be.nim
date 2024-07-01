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
  std/[sets, tables],
  eth/common,
  results,
  stew/interval_set,
  ../../aristo,
  ../aristo_walk/persistent,
  ".."/[aristo_desc, aristo_get, aristo_layers]

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc toNodeBE(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDbRef;                   # Database, top layer
      ): Result[NodeRef,VertexID] =
  ## Similar to `toNode()` but fetching from the backend only
  case vtx.vType:
  of Leaf:
    let node = NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.stoID
      if vid.isValid:
        let rc = db.getKeyBE vid
        if rc.isErr or not rc.value.isValid:
          return err(vid)
        node.key[0] = rc.value
    return ok node
  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let rc = db.getKeyBE vid
        if rc.isOk and rc.value.isValid:
          node.key[n] = rc.value
        else:
          return err(vid)
      else:
        node.key[n] = VOID_HASH_KEY
    return ok node
  of Extension:
    let
      vid = vtx.eVid
      rc = db.getKeyBE vid
    if rc.isOk and rc.value.isValid:
      let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
      node.key[0] = rc.value
      return ok node
    return err(vid)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkBE*[T: RdbBackendRef|MemBackendRef|VoidBackendRef](
    _: type T;
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Make sure that each vertex has a Merkle hash and vice versa. Also check
  ## the vertex ID generator state.
  var topVidBe = VertexID(0)

  for (vid,vtx) in T.walkVtxBe db:
    if topVidBe < vid:
      topVidBe = vid
    if not vtx.isValid:
      return err((vid,CheckBeVtxInvalid))
    case vtx.vType:
    of Leaf:
      discard
    of Branch:
      block check42Links:
        var seen = false
        for n in 0 .. 15:
          if vtx.bVid[n].isValid:
            if seen:
              break check42Links
            seen = true
        return err((vid,CheckBeVtxBranchLinksMissing))
    of Extension:
      if vtx.ePfx.len == 0:
        return err((vid,CheckBeVtxExtPfxMissing))

  for (vid,key) in T.walkKeyBe db:
    if topVidBe < vid:
      topVidBe = vid
    let vtx = db.getVtxBE(vid).valueOr:
      return err((vid,CheckBeVtxMissing))

  # Compare calculated `vTop` against database state
  if topVidBe.isValid:
    let vidTuvBe = block:
      let rc = db.getTuvBE()
      if rc.isOk:
        rc.value
      elif rc.error == GetTuvNotFound:
        VertexID(0)
      else:
        return err((VertexID(0),rc.error))
    if vidTuvBe != topVidBe:
      # All vertices and keys between `topVidBe` and `vidTuvBe` must have
      # been deleted.
      for vid in max(topVidBe + 1, VertexID(LEAST_FREE_VID)) .. vidTuvBe:
        if db.getVtxBE(vid).isOk or db.getKeyBE(vid).isOk:
          return err((vid,CheckBeGarbledVTop))

  # Check layer cache against backend
  block:
    var topVidCache = VertexID(0)

    # Check structural table
    for (vid,vtx) in db.layersWalkVtx:
      if vtx.isValid and topVidCache < vid:
        topVidCache = vid
      let key = db.layersGetKey(vid).valueOr: VOID_HASH_KEY
      if not vtx.isValid:
        # Some vertex is to be deleted, the key must be empty
        if key.isValid:
          return err((vid,CheckBeCacheKeyNonEmpty))

    # Check key table
    var list: seq[VertexID]
    for (vid,key) in db.layersWalkKey:
      if key.isValid and topVidCache < vid:
        topVidCache = vid
      list.add vid
      let vtx = db.getVtx vid
      if db.layersGetVtx(vid).isErr and not vtx.isValid:
        return err((vid,CheckBeCacheKeyDangling))

    # Check vTop
    if topVidCache.isValid and topVidCache != db.vTop:
      # All vertices and keys between `topVidCache` and `db.vTop` must have
      # been deleted.
      for vid in max(db.vTop + 1, VertexID(LEAST_FREE_VID)) .. topVidCache:
        if db.layersGetVtxOrVoid(vid).isValid or
           db.layersGetKeyOrVoid(vid).isValid:
          return err((db.vTop,CheckBeCacheGarbledVTop))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
