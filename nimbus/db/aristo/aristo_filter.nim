# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie filter management
## =============================================
##

import
  std/[options, sequtils, tables],
  results,
  "."/[aristo_desc, aristo_get, aristo_vid]

type
  StateRootPair = object
    be: HashKey
    fg: HashKey

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getBeStateRoot(
    db: AristoDbRef;
      ): Result[HashKey,AristoError] =
  let rc = db.getKeyBackend VertexID(1)
  if rc.isOk:
    return ok(rc.value)
  if rc.error == GetKeyNotFound:
    return ok(VOID_HASH_KEY)
  err(rc.error)

proc getLayerStateRoots(
    db: AristoDbRef;
    layer: AristoLayerRef;
    extendOK: bool;
      ): Result[StateRootPair,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  var spr: StateRootPair
  block:
    let rc = db.getBeStateRoot()
    if rc.isErr:
      return err(rc.error)
    spr.be = rc.value
  block:
    spr.fg = layer.kMap.getOrVoid(VertexID 1).key
    if spr.fg.isValid:
      return ok(spr)
  if extendOK:
    let vid = layer.pAmk.getOrVoid HashLabel(root: VertexID(1), key: spr.be)
    if vid == VertexID(1):
      spr.fg = spr.be
      return ok(spr)
  if layer.sTab.len == 0 and
     layer.kMap.len == 0 and
     layer.pAmk.len == 0:
    return err(FilPrettyPointlessLayer)
  err(FilStateRootMismatch)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func bulk*(filter: AristoFilterRef): int =
  ## Some measurement for the size of the filter calculated as the length of
  ## the `sTab[]` table plus the lengthof the `kMap[]` table. This can be used
  ## to set a threshold when to flush the staging area to the backend DB to
  ## be used in `stow()`.
  ##
  ## The `filter` argument may be `nil`, i.e. `AristoFilterRef(nil).bulk == 0`
  if filter.isNil: 0 else: filter.sTab.len + filter.kMap.len

func bulk*(layer: AristolayerRef): int =
  ## Variant of `bulk()` for layers rather than filters.
  ##
  ## The `layer` argument may be `nil`, i.e. `AristoLayerRef(nil).bulk == 0`
  if layer.isNil: 0 else: layer.sTab.len + layer.kMap.len

# ------------------------------------------------------------------------------
# Public functions, construct filters
# ------------------------------------------------------------------------------

proc fwdFilter*(
    db: AristoDbRef;
    layer: AristoLayerRef;
    extendOK = false;
      ): Result[AristoFilterRef,(VertexID,AristoError)] =
  ## Assemble forward delta, i.e. changes to the backend equivalent to applying
  ## the current top layer.
  ##
  ## Typically, the `layer` layer would reflect a change of the MPT but there
  ## is the case of partial MPTs sent over the network when synchronising (see
  ## `snap` protocol.) In this case, the state root might not see a change on
  ## the `layer` layer which would result in an error unless the argument
  ## `extendOK` is set `true`
  ##
  ## This delta is taken against the current backend including optional
  ## read-only filter.
  ##
  # Register the Merkle hash keys of the MPT where this reverse filter will be
  # applicable: `be => fg`
  let (srcRoot, trgRoot) = block:
    let rc = db.getLayerStateRoots(layer, extendOk)
    if rc.isOK:
      (rc.value.be, rc.value.fg)
    elif rc.error == FilPrettyPointlessLayer:
      return ok AristoFilterRef(vGen: none(seq[VertexID]))
    else:
      return err((VertexID(1), rc.error))

  ok AristoFilterRef(
    src:  srcRoot,
    sTab: layer.sTab,
    kMap: layer.kMap.pairs.toSeq.mapIt((it[0],it[1].key)).toTable,
    vGen: some(layer.vGen.vidReorg), # Compact recycled IDs
    trg:  trgRoot)

# ------------------------------------------------------------------------------
# Public functions, apply/install filters
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDbRef;
    filter: AristoFilterRef;
      ): Result[void,(VertexID,AristoError)] =
  ## Merge argument `filter` to the filter layer.
  ##
  ## Comparing before and after merge
  ## ::
  ##   current                           | merged
  ##   ----------------------------------+--------------------------------
  ##   trg2    --filter--   (src2==trg1) |
  ##                                     | trg2 --newFilter-- (src1==trg0)
  ##   trg1 --db.roFilter-- (src1==trg0) |
  ##                                     |
  ##   trg0 --db.backend                 | trg0 --db.backend
  ##                                     |
  let beRoot = block:
    let rc = db.getBeStateRoot()
    if rc.isErr:
      return err((VertexID(1),FilStateRootMissing))
    rc.value

  if filter.vGen.isNone:
    # Blind argument filter
    if db.roFilter.isNil:
      # Force read-only system
      db.roFilter = AristoFilterRef(
        src: beRoot,
        trg: beRoot,
        vGen: none(seq[VertexID]))
    return ok()

  # Simple case: no read-only filter yet
  if db.roFilter.isNil or db.roFilter.vGen.isNone:
    if filter.src != beRoot:
      return err((VertexID(1),FilStateRootMismatch))
    db.roFilter = filter
    return ok()

  # Verify merge stackability into existing read-only filter
  if filter.src != db.roFilter.trg:
    return err((VertexID(1),FilStateRootMismatch))

  # Merge `filter` into `roFilter` as `newFilter`. There is no need to deep
  # copy table vertices as they will not be modified.
  let newFilter = AristoFilterRef(
    src:  db.roFilter.src,
    sTab: db.roFilter.sTab,
    kMap: db.roFilter.kMap,
    vGen: filter.vGen,
    trg:  filter.trg)

  for (vid,vtx) in filter.sTab.pairs:
    if vtx.isValid or not newFilter.sTab.hasKey vid:
      newFilter.sTab[vid] = vtx
    elif newFilter.sTab.getOrVoid(vid).isValid:
      let rc = db.getVtxUnfilteredBackend vid
      if rc.isOk:
        newFilter.sTab[vid] = vtx # VertexRef(nil)
      elif rc.error == GetVtxNotFound:
        newFilter.sTab.del vid
      else:
        return err((vid,rc.error))

  for (vid,key) in filter.kMap.pairs:
    if key.isValid or not newFilter.kMap.hasKey vid:
      newFilter.kMap[vid] = key
    elif newFilter.kMap.getOrVoid(vid).isValid:
      let rc = db.getKeyUnfilteredBackend vid
      if rc.isOk:
        newFilter.kMap[vid] = key # VOID_HASH_KEY
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del vid
      else:
        return err((vid,rc.error))

  db.roFilter = newFilter
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
