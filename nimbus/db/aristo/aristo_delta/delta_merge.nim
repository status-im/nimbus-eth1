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
  let lowerTrg = lower.kMap.getOrVoid (VertexID(1), VertexID(1))

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = LayerDeltaRef(
    sTab: lower.sTab,
    kMap: lower.kMap,
    vTop: upper.vTop)

  for (rvid,vtx) in upper.sTab.pairs:
    if vtx.isValid or not newFilter.sTab.hasKey rvid:
      newFilter.sTab[rvid] = vtx
    elif newFilter.sTab.getOrVoid(rvid).isValid:
      let rc = db.getVtxUbe rvid
      if rc.isOk:
        newFilter.sTab[rvid] = vtx # VertexRef(nil)
      elif rc.error == GetVtxNotFound:
        newFilter.sTab.del rvid
      else:
        return err((rvid.vid,rc.error))

  for (rvid,key) in upper.kMap.pairs:
    if key.isValid or not newFilter.kMap.hasKey rvid:
      newFilter.kMap[rvid] = key
    elif newFilter.kMap.getOrVoid(rvid).isValid:
      let rc = db.getKeyUbe rvid
      if rc.isOk:
        newFilter.kMap[rvid] = key
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del rvid
      else:
        return err((rvid.vid,rc.error))

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
