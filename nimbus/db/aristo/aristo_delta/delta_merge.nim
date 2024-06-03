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
  ## The resuting filter has no `FilterID` set.
  ##
  ## Comparing before and after merge
  ## ::
  ##   arguments                       | merged result
  ##   --------------------------------+------------------------------------
  ##   (src2==trg1) --> upper --> trg2 |
  ##                                   | (src1==trg0) --> newFilter --> trg2
  ##   (src1==trg0) --> lower --> trg1 |
  ##                                   |
  ##              beStateRoot --> trg0 |
  ##
  # Degenerate case: `upper` is void
  if lower.isNil:
    if upper.isNil:
      # Even more degenerate case when both filters are void
      return ok LayerDeltaRef(nil)
    if upper.src != beStateRoot:
      return err((VertexID(1),FilStateRootMismatch))
    return ok(upper)

  # Degenerate case: `upper` is non-trivial and `lower` is void
  if upper.isNil:
    if lower.src != beStateRoot:
      return err((VertexID(0), FilStateRootMismatch))
    return ok(lower)

  # Verify stackability
  let lowerTrg = lower.kMap.getOrVoid VertexID(1)
  if upper.src != lowerTrg:
    return err((VertexID(0), FilTrgSrcMismatch))
  if lower.src != beStateRoot:
    return err((VertexID(0), FilStateRootMismatch))

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = LayerDeltaRef(
    src:  lower.src,
    sTab: lower.sTab,
    kMap: lower.kMap,
    vGen: upper.vGen)

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

  # Check consistency
  if (newFilter.src == newFilter.kMap.getOrVoid(VertexID 1)) !=
       (newFilter.sTab.len == 0 and newFilter.kMap.len == 0):
    return err((VertexID(0),FilSrcTrgInconsistent))

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
