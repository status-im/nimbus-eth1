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
  std/[sequtils, sets, typetraits],
  eth/[common, trie/nibbles],
  results,
  ".."/[aristo_desc, aristo_get, aristo_layers, aristo_serialise, aristo_utils]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTopStrict*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  # No need to specify zero keys if implied by a leaf path with valid target
  # vertex ID (i.e. not deleted).
  var zeroKeys: HashSet[VertexID]
  for (vid,vtx) in db.layersWalkVtx:
    let key = db.layersGetKeyOrVoid vid

    if not vtx.isValid:
      if key.isValid:
        return err((vid,CheckStkVtxKeyMismatch))
      else: # Empty key flags key is for update
        zeroKeys.incl vid

    elif key.isValid:
      # So `vtx` and `key` exist
      let node = vtx.toNode(db).valueOr:
        return err((vid,CheckStkVtxIncomplete))
      if key != node.digestTo(HashKey):
        return err((vid,CheckStkVtxKeyMismatch))

    elif db.dirty.len == 0 or db.layersGetKey(vid).isErr:
      # So `vtx` exists but not `key`, so cache is supposed dirty and the
      # vertex has a zero entry.
      return err((vid,CheckStkVtxKeyMissing))

    else: # Empty key flags key is for update
      zeroKeys.incl vid

  for (vid,key) in db.layersWalkKey:
    if not key.isValid and vid notin zeroKeys:
      if not db.getVtx(vid).isValid:
        return err((vid,CheckStkKeyStrayZeroEntry))

  ok()


proc checkTopProofMode*(
    db: AristoDbRef;                               # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  if 0 < db.pPrf.len:
    for vid in db.pPrf:
      let vtx = db.layersGetVtxOrVoid vid
      if vtx.isValid:
        let node = vtx.toNode(db).valueOr:
          return err((vid,CheckRlxVtxIncomplete))

        let key = db.layersGetKeyOrVoid vid
        if not key.isValid:
          return err((vid,CheckRlxVtxKeyMissing))
        if key != node.digestTo(HashKey):
          return err((vid,CheckRlxVtxKeyMismatch))
  else:
    for (vid,key) in db.layersWalkKey:
      if key.isValid:                              # Otherwise to be deleted
        let vtx = db.getVtx vid
        if vtx.isValid:
          let node = vtx.toNode(db).valueOr:
            continue
          if key != node.digestTo(HashKey):
            return err((vid,CheckRlxVtxKeyMismatch))
  ok()


proc checkTopCommon*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  # Some `kMap[]` entries may ne void indicating backend deletion
  let
    kMapCount = db.layersWalkKey.toSeq.mapIt(it[1]).filterIt(it.isValid).len
    kMapNilCount = db.layersWalkKey.toSeq.len - kMapCount
    vTop = db.vTop
  var
    topVid = VertexID(0)
    stoRoots: HashSet[VertexID]

  # Collect leafs and check deleted entries
  var nNilVtx = 0
  for (vid,vtx) in db.layersWalkVtx:
    if vtx.isValid:
      if topVid < vid:
        topVid = vid
      case vtx.vType:
      of Leaf:
        if vtx.lData.pType == AccountData:
          let stoVid = vtx.lData.account.storageID
          if stoVid.isValid:
            if stoVid in stoRoots:
              return err((stoVid,CheckAnyVidSharedStorageRoot))
            if vTop < stoVid:
              return err((stoVid,CheckAnyVidDeadStorageRoot))
            stoRoots.incl stoVid
      of Branch:
        block check42Links:
          var seen = false
          for n in 0 .. 15:
            if vtx.bVid[n].isValid:
              if seen:
                break check42Links
              seen = true
          return err((vid,CheckAnyVtxBranchLinksMissing))
      of Extension:
        if vtx.ePfx.len == 0:
          return err((vid,CheckAnyVtxExtPfxMissing))
    else:
      nNilVtx.inc
      let rc = db.layersGetKey vid
      if rc.isErr:
        return err((vid,CheckAnyVtxEmptyKeyMissing))
      if rc.value.isValid:
        return err((vid,CheckAnyVtxEmptyKeyExpected))

  if vTop.distinctBase < LEAST_FREE_VID:
    # Verify that all vids are below `LEAST_FREE_VID`
    if topVid.distinctBase < LEAST_FREE_VID:
      for (vid,key) in db.layersWalkKey:
        if key.isValid and LEAST_FREE_VID <= vid.distinctBase:
          return err((topVid,CheckAnyVTopUnset))

  # If present, there are at least as many deleted hashes as there are deleted
  # vertices.
  if kMapNilCount != 0 and kMapNilCount < nNilVtx:
    return err((VertexID(0),CheckAnyVtxEmptyKeyMismatch))

  for vid in db.pPrf:
    if db.layersGetKey(vid).isErr:
      return err((vid,CheckAnyVtxLockWithoutKey))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

