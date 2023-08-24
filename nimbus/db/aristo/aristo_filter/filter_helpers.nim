# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/tables,
  results,
  ".."/[aristo_desc, aristo_get],
  ./filter_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getLayerStateRoots*(
    db: AristoDbRef;
    layer: LayerRef;
    chunkedMpt: bool;
      ): Result[StateRootPair,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  var spr: StateRootPair

  spr.be = block:
    let rc = db.getKeyBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  block:
    spr.fg = layer.kMap.getOrVoid(VertexID 1).key
    if spr.fg.isValid:
      return ok(spr)

  if chunkedMpt:
    let vid = layer.pAmk.getOrVoid HashLabel(root: VertexID(1), key: spr.be)
    if vid == VertexID(1):
      spr.fg = spr.be
      return ok(spr)

  if layer.sTab.len == 0 and
     layer.kMap.len == 0 and
     layer.pAmk.len == 0:
    return err(FilPrettyPointlessLayer)

  err(FilStateRootMismatch)


proc merge*(
    db: AristoDbRef;
    upper: FilterRef;                          # Src filter, `nil` is ok
    lower: FilterRef;                          # Trg filter, `nil` is ok
    beStateRoot: HashKey;                      # Merkle hash key
      ): Result[FilterRef,(VertexID,AristoError)] =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Comparing before and after merge
  ## ::
  ##   current                     | merged
  ##   ----------------------------+--------------------------------
  ##   trg2 --upper-- (src2==trg1) |
  ##                               | trg2 --newFilter-- (src1==trg0)
  ##   trg1 --lower-- (src1==trg0) |
  ##                               |
  ##   trg0 --beStateRoot          | trg0 --beStateRoot
  ##                               |
  ##
  # Degenerate case: `upper` is void
  if lower.isNil:
    if upper.isNil:
      # Even more degenerate case when both filters are void
      return ok FilterRef(nil)
    if upper.src != beStateRoot:
      return err((VertexID(1),FilStateRootMismatch))
    return ok(upper)

  # Degenerate case: `upper` is non-trivial and `lower` is void
  if upper.isNil:
    if lower.src != beStateRoot:
      return err((VertexID(0), FilStateRootMismatch))
    return ok(lower)

  # Verify stackability
  if upper.src != lower.trg or
     lower.src != beStateRoot:
    return err((VertexID(0), FilStateRootMismatch))

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = FilterRef(
    src:  lower.src,
    sTab: lower.sTab,
    kMap: lower.kMap,
    vGen: upper.vGen,
    trg:  upper.trg)

  for (vid,vtx) in upper.sTab.pairs:
    if vtx.isValid or not newFilter.sTab.hasKey vid:
      newFilter.sTab[vid] = vtx
    elif newFilter.sTab.getOrVoid(vid).isValid:
      let rc = db.getVtxUBE vid
      if rc.isOk:
        newFilter.sTab[vid] = vtx # VertexRef(nil)
      elif rc.error == GetVtxNotFound:
        newFilter.sTab.del vid
      else:
        return err((vid,rc.error))

  for (vid,key) in upper.kMap.pairs:
    if key.isValid or not newFilter.kMap.hasKey vid:
      newFilter.kMap[vid] = key
    elif newFilter.kMap.getOrVoid(vid).isValid:
      let rc = db.getKeyUBE vid
      if rc.isOk:
        newFilter.kMap[vid] = key # VOID_HASH_KEY
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del vid
      else:
        return err((vid,rc.error))

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
