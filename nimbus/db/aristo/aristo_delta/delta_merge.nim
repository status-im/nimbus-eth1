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
    upper: LayerRef;                           # new filter, `nil` is ok
    lower: LayerRef;                           # Trg filter, `nil` is ok
      ): Result[LayerRef,(VertexID,AristoError)] =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Note that the namimg `upper` and `lower` indicate that the filters are
  ## stacked and the database access is `upper -> lower -> backend`.
  ##
  # Degenerate case: `upper` is void
  if lower.isNil:
    if upper.isNil:
      # Even more degenerate case when both filters are void
      return ok LayerRef(nil)
    return ok(upper)

  # Degenerate case: `upper` is non-trivial and `lower` is void
  if upper.isNil:
    return ok(lower)

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = LayerRef(
    sTab: lower.sTab,
    kMap: lower.kMap,
    vTop: upper.vTop)

  # Note the similarity to the `layersMergeOnto()` function. The difference
  # here is that blind/zero vertex entries are checked against the database
  # and ignored if missing there.
  #
  # FIXME: Can we do without and just use `layersMergeOnto()`?
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

  # Ditto (see earlier comment)
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

  for (accPath,leafVtx) in upper.accLeaves.pairs:
    newFilter.accLeaves[accPath] = leafVtx

  for (mixPath,leafVtx) in upper.stoLeaves.pairs:
    newFilter.stoLeaves[mixPath] = leafVtx

  ok newFilter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
