# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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

proc merge*(
    db: AristoDbRef;
    upper: FilterRef;                          # Src filter, `nil` is ok
    lower: FilterRef;                          # Trg filter, `nil` is ok
    beStateRoot: Hash256;                      # Merkle hash key
      ): Result[FilterRef,(VertexID,AristoError)] =
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
  if upper.src != lower.trg:
    return err((VertexID(0), FilTrgSrcMismatch))
  if lower.src != beStateRoot:
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
        newFilter.kMap[vid] = key
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del vid
      else:
        return err((vid,rc.error))

  ok newFilter


proc merge*(
    upper: FilterRef;                          # filter, not `nil`
    lower: FilterRef;                          # filter, not `nil`
      ): Result[FilterRef,(VertexID,AristoError)] =
  ## Variant of `merge()` without optimising filters relative to the backend.
  ## Also, filter arguments `upper` and `lower` are expected not`nil`.
  ## Otherwise an error is returned.
  ##
  ## Comparing before and after merge
  ## ::
  ##   arguments                       | merged result
  ##   --------------------------------+--------------------------------
  ##   (src2==trg1) --> upper --> trg2 |
  ##                                   | (src1==trg0) --> newFilter --> trg2
  ##   (src1==trg0) --> lower --> trg1 |
  ##                                   |
  if upper.isNil or lower.isNil:
    return err((VertexID(0),FilNilFilterRejected))

  # Verify stackability
  if upper.src != lower.trg:
    return err((VertexID(0), FilTrgSrcMismatch))

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = FilterRef(
    fid:  upper.fid,
    src:  lower.src,
    sTab: lower.sTab,
    kMap: lower.kMap,
    vGen: upper.vGen,
    trg:  upper.trg)

  for (vid,vtx) in upper.sTab.pairs:
    newFilter.sTab[vid] = vtx

  for (vid,key) in upper.kMap.pairs:
    newFilter.kMap[vid] = key

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
