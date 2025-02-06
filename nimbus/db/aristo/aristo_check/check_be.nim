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
# Public functions
# ------------------------------------------------------------------------------

proc checkBE*[T: RdbBackendRef|MemBackendRef|VoidBackendRef](
    _: type T;
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  ## Make sure that each vertex has a Merkle hash and vice versa. Also check
  ## the vertex ID generator state.
  var topVidBe: RootedVertexID = (VertexID(0), VertexID(0))

  for (rvid,vtx) in T.walkVtxBe db:
    if topVidBe.vid < rvid.vid:
      topVidBe = rvid
    if not vtx.isValid:
      return err((rvid.vid,CheckBeVtxInvalid))
    case vtx.vType:
    of Leaf:
      discard
    of Branch:
      block check42Links:
        var seen = false
        for _, _ in vtx.pairs():
          if seen:
            break check42Links
          seen = true
        return err((rvid.vid,CheckBeVtxBranchLinksMissing))

  for (rvid,key) in T.walkKeyBe db:
    if topVidBe.vid < rvid.vid:
      topVidBe = rvid
    let _ = db.getVtxBE(rvid).valueOr:
      return err((rvid.vid,CheckBeVtxMissing))

  # Compare calculated `vTop` against database state
  # TODO
  # if topVidBe.isValid:
  #   let vidTuvBe = block:
  #     let rc = db.getTuvBE()
  #     if rc.isOk:
  #       rc.value
  #     elif rc.error == GetTuvNotFound:
  #       VertexID(0)
  #     else:
  #       return err((VertexID(0),rc.error))
  #   if vidTuvBe != topVidBe:
  #     # All vertices and keys between `topVidBe` and `vidTuvBe` must have
  #     # been deleted.
  #     for vid in max(topVidBe + 1, VertexID(LEAST_FREE_VID)) .. vidTuvBe:
  #       if db.getVtxBE(vid).isOk or db.getKeyBE(vid).isOk:
  #         return err((vid,CheckBeGarbledVTop))

  # Check layer cache against backend
  block:
    var topVidCache: RootedVertexID = (VertexID(0), VertexID(0))

    # Check structural table
    for (rvid,vtx) in db.layersWalkVtx:
      if vtx.isValid and topVidCache.vid < rvid.vid:
        topVidCache = rvid
      let (key, _) = db.layersGetKey(rvid).valueOr: (VOID_HASH_KEY, 0)
      if not vtx.isValid:
        # Some vertex is to be deleted, the key must be empty
        if key.isValid:
          return err((rvid.vid,CheckBeCacheKeyNonEmpty))

    # Check key table
    var list: seq[RootedVertexID]
    for (rvid,key) in db.layersWalkKey:
      if key.isValid and topVidCache.vid < rvid.vid:
        topVidCache = rvid
      list.add rvid
      let vtx = db.getVtx rvid
      if db.layersGetVtx(rvid).isErr and not vtx.isValid:
        return err((rvid.vid,CheckBeCacheKeyDangling))

    # Check vTop
    # TODO
    # if topVidCache.isValid and topVidCache != db.vTop:
    #   # All vertices and keys between `topVidCache` and `db.vTop` must have
    #   # been deleted.
    #   for vid in max(db.vTop + 1, VertexID(LEAST_FREE_VID)) .. topVidCache:
    #     if db.layersGetVtxOrVoid(vid).isValid or
    #        db.layersGetKeyOrVoid(vid).isValid:
    #       return err((db.vTop,CheckBeCacheGarbledVTop))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
