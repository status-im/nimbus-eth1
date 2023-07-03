# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets, tables],
  eth/common,
  stew/results,
  ../aristo_hashify/hashify_helper,
  ".."/[aristo_desc, aristo_get]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkCacheStrict*(
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  for (vid,vtx) in db.top.sTab.pairs:
    if vtx.isValid:
      let rc = vtx.toNode db
      if rc.isErr:
        return err((vid,CheckStkVtxIncomplete))

      let lbl = db.top.kMap.getOrVoid vid
      if not lbl.isValid:
        return err((vid,CheckStkVtxKeyMissing))
      if lbl.key != rc.value.toHashKey:
        return err((vid,CheckStkVtxKeyMismatch))

      let revVid = db.top.pAmk.getOrVoid lbl
      if not revVid.isValid:
        return err((vid,CheckStkRevKeyMissing))
      if revVid != vid:
        return err((vid,CheckStkRevKeyMismatch))

  if 0 < db.top.pAmk.len and db.top.pAmk.len < db.top.sTab.len:
    # Cannot have less changes than cached entries
    return err((VertexID(0),CheckStkVtxCountMismatch))

  ok()


proc checkCacheRelaxed*(
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  if 0 < db.top.pPrf.len:
    for vid in db.top.pPrf:
      let vtx = db.top.sTab.getOrVoid vid
      if vtx.isValid:
        let rc = vtx.toNode db
        if rc.isErr:
          return err((vid,CheckRlxVtxIncomplete))

        let lbl = db.top.kMap.getOrVoid vid
        if not lbl.isValid:
          return err((vid,CheckRlxVtxKeyMissing))
        if lbl.key != rc.value.toHashKey:
          return err((vid,CheckRlxVtxKeyMismatch))

        let revVid = db.top.pAmk.getOrVoid lbl
        if not revVid.isValid:
          return err((vid,CheckRlxRevKeyMissing))
        if revVid != vid:
          return err((vid,CheckRlxRevKeyMismatch))
  else:
    for (vid,lbl) in db.top.kMap.pairs:
      if lbl.isValid:                              # Otherwise to be deleted
        let vtx = db.getVtx vid
        if vtx.isValid:
          let rc = vtx.toNode db
          if rc.isOk:
            if lbl.key != rc.value.toHashKey:
              return err((vid,CheckRlxVtxKeyMismatch))

            let revVid = db.top.pAmk.getOrVoid lbl
            if not revVid.isValid:
              return err((vid,CheckRlxRevKeyMissing))
            if revVid != vid:
              return err((vid,CheckRlxRevKeyMissing))
            if revVid != vid:
              return err((vid,CheckRlxRevKeyMismatch))
  ok()


proc checkCacheCommon*(
    db: AristoDb;                      # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  # Some `kMap[]` entries may ne void indicating backend deletion
  let
    kMapCount = db.top.kMap.values.toSeq.filterIt(it.isValid).len
    kMapNilCount = db.top.kMap.len - kMapCount

  # Check deleted entries
  var nNilVtx = 0
  for (vid,vtx) in db.top.sTab.pairs:
    if not vtx.isValid:
      nNilVtx.inc
      let rc = db.getVtxBackend vid
      if rc.isErr:
        return err((vid,CheckAnyVidVtxMissing))
      if not db.top.kMap.hasKey vid:
        return err((vid,CheckAnyVtxEmptyKeyMissing))
      if db.top.kMap.getOrVoid(vid).isValid:
        return err((vid,CheckAnyVtxEmptyKeyExpected))

  # If present, there are at least as many deleted hashes as there are deleted
  # vertices.
  if kMapNilCount != 0 and kMapNilCount < nNilVtx:
    if noisy: echo ">>> checkCommon (4)",
      " nNilVtx=", nNilVtx,
      " kMapNilCount=", kMapNilCount
    return err((VertexID(0),CheckAnyVtxEmptyKeyMismatch))

  if db.top.pAmk.len != kMapCount:
    var knownKeys: HashSet[VertexID]
    for (key,vid) in db.top.pAmk.pairs:
      if not db.top.kMap.hasKey(vid):
        return err((vid,CheckAnyRevVtxMissing))
      if vid in knownKeys:
        return err((vid,CheckAnyRevVtxDup))
      knownKeys.incl vid
    return err((VertexID(0),CheckAnyRevCountMismatch)) # should not apply(!)

  for vid in db.top.pPrf:
    if not db.top.kMap.hasKey(vid):
      return err((vid,CheckAnyVtxLockWithoutKey))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

