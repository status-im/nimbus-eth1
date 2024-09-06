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
  ".."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deltaMerge*(
    upper: LayerRef;                   # Think of `top`, `nil` is ok
    modUpperOk: bool;                  # May re-use/modify `upper`
    lower: LayerRef;                   # Think of `balancer`, `nil` is ok
    modLowerOk: bool;                  # May re-use/modify `lower`
      ): LayerRef =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Note that the namimg `upper` and `lower` indicate that the filters are
  ## stacked and the database access is `upper -> lower -> backend`.
  ##
  if lower.isNil:
    # Degenerate case: `upper` is void
    result = upper

  elif upper.isNil:
    # Degenerate case: `lower` is void
    result = lower

  elif modLowerOk:
    # Can modify `lower` which is the prefered action mode but applies only
    # in cases where the `lower` argument is not shared.
    lower.vTop = upper.vTop
    layersMergeOnto(upper, lower[])
    result = lower

  elif not modUpperOk:
    # Cannot modify any argument layers.
    result = LayerRef(
      sTab:      lower.sTab, # shallow copy (entries will not be modified)
      kMap:      lower.kMap,
      accLeaves: lower.accLeaves,
      stoLeaves: lower.stoLeaves,
      vTop:      upper.vTop)
    layersMergeOnto(upper, result[])

  else:
    # Otherwise avoid copying some tables by modifying `upper`. This is not
    # completely free as the merge direction changes to merging the `lower`
    # layer up into the higher prioritised `upper` layer (note that the `lower`
    # argument filter is read-only.) Here again, the `upper` argument must not
    # be a shared layer/filter.
    for (rvid,vtx) in lower.sTab.pairs:
      if not upper.sTab.hasKey(rvid):
        upper.sTab[rvid] = vtx

    for (rvid,key) in lower.kMap.pairs:
      if not upper.kMap.hasKey(rvid):
        upper.kMap[rvid] = key

    for (accPath,leafVtx) in lower.accLeaves.pairs:
      if not upper.accLeaves.hasKey(accPath):
        upper.accLeaves[accPath] = leafVtx

    for (mixPath,leafVtx) in lower.stoLeaves.pairs:
      if not upper.stoLeaves.hasKey(mixPath):
        upper.stoLeaves[mixPath] = leafVtx
    result = upper

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
