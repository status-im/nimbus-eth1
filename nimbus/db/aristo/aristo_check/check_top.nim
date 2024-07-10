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
  eth/common,
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
  for (rvid,vtx) in db.layersWalkVtx:
    let key = db.layersGetKeyOrVoid rvid

    if not vtx.isValid:
      if key.isValid:
        return err((rvid.vid,CheckStkVtxKeyMismatch))
      else: # Empty key flags key is for update
        zeroKeys.incl rvid.vid

    elif key.isValid:
      # So `vtx` and `key` exist
      let node = vtx.toNode(rvid.root, db).valueOr:
        return err((rvid.vid,CheckStkVtxIncomplete))
      if key != node.digestTo(HashKey):
        return err((rvid.vid,CheckStkVtxKeyMismatch))

    elif db.layersGetKey(rvid).isErr:
      # So `vtx` exists but not `key`, so cache is supposed dirty and the
      # vertex has a zero entry.
      # TODO when we're writing a brand new entry, we don't write a zero key
      #      to the database to avoid the unnecessary delete traffic..
      discard # return err((rvid.vid,CheckStkVtxKeyMissing))

    else: # Empty key flags key is for update
      zeroKeys.incl rvid.vid

  for (rvid,key) in db.layersWalkKey:
    if not key.isValid and rvid.vid notin zeroKeys:
      if not db.getVtx(rvid).isValid:
        return err((rvid.vid,CheckStkKeyStrayZeroEntry))

  ok()


proc checkTopProofMode*(
    db: AristoDbRef;                               # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  for (rvid,key) in db.layersWalkKey:
    if key.isValid:                              # Otherwise to be deleted
      let vtx = db.getVtx rvid
      if vtx.isValid:
        let node = vtx.toNode(rvid.root, db).valueOr:
          continue
        if key != node.digestTo(HashKey):
          return err((rvid.vid,CheckRlxVtxKeyMismatch))
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
  for (rvid,vtx) in db.layersWalkVtx:
    if vtx.isValid:
      if topVid < rvid.vid:
        topVid = rvid.vid
      case vtx.vType:
      of Leaf:
        if vtx.lData.pType == AccountData:
          let stoVid = vtx.lData.stoID
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
          return err((rvid.vid,CheckAnyVtxBranchLinksMissing))
      of Extension:
        if vtx.ePfx.len == 0:
          return err((rvid.vid,CheckAnyVtxExtPfxMissing))
    else:
      nNilVtx.inc
      let rc = db.layersGetKey rvid
      if rc.isErr:
        return err((rvid.vid,CheckAnyVtxEmptyKeyMissing))
      if rc.value.isValid:
        return err((rvid.vid,CheckAnyVtxEmptyKeyExpected))

  if vTop.distinctBase < LEAST_FREE_VID:
    # Verify that all vids are below `LEAST_FREE_VID`
    if topVid.distinctBase < LEAST_FREE_VID:
      for (rvid,key) in db.layersWalkKey:
        if key.isValid and LEAST_FREE_VID <= rvid.vid.distinctBase:
          return err((topVid,CheckAnyVTopUnset))

  # If present, there are at least as many deleted hashes as there are deleted
  # vertices.
  if kMapNilCount != 0 and kMapNilCount < nNilVtx:
    return err((VertexID(0),CheckAnyVtxEmptyKeyMismatch))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

