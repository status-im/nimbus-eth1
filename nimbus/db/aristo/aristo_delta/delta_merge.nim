# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/tables,
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deltaMerge*(
    db: AristoDbRef;
    upper: LayerDeltaRef;                      # Src filter, `nil` is ok
    lower: LayerDeltaRef;                      # Trg filter, `nil` is ok
    beStateRoot: HashKey;                      # Merkle hash key
      ): Result[LayerDeltaRef,(VertexID,AristoError)] =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Note that the namimg `upper` and `lower` indicate that the filters are
  ## stacked and the database access is `upper -> lower -> backend` whereas
  ## the `src/trg` matching logic goes the other way round.
  ##
  # Degenerate case: `upper` is void
  if lower.isNil:
    if upper.isNil:
      # Even more degenerate case when both filters are void
      return ok LayerDeltaRef(nil)
    return ok(upper)

  # Degenerate case: `upper` is non-trivial and `lower` is void
  if upper.isNil:
    return ok(lower)

  # Verify stackability
  let lowerTrg = lower.kMap.getOrVoid VertexID(1)

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = LayerDeltaRef(
    sTab: lower.sTab,
    kMap: lower.kMap,
    vTop: upper.vTop)

  for (vid,vtx) in upper.sTab.pairs:
    if vtx.isValid or not newFilter.sTab.hasKey vid:
      newFilter.sTab[vid] = vtx
    elif newFilter.sTab.getOrVoid(vid).isValid:
      let rc = db.getVtxUbe vid
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
      let rc = db.getKeyUbe vid
      if rc.isOk:
        newFilter.kMap[vid] = key
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del vid
      else:
        return err((vid,rc.error))

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
