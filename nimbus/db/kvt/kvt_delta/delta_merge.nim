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
  ../kvt_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc layersMergeOnto(src: LayerRef; trg: var LayerObj) =
  for (key,val) in src.sTab.pairs:
    trg.sTab[key] = val

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
    layersMergeOnto(upper, lower[])
    result = lower

  elif not modUpperOk:
    # Cannot modify any argument layers.
    result = LayerRef(sTab: lower.sTab)
    layersMergeOnto(upper, result[])

  else:
    # Otherwise avoid copying some tables by modifyinh `upper`. This is not
    # completely free as the merge direction changes to merging the `lower`
    # layer up into the higher prioritised `upper` layer (note that the `lower`
    # argument filter is read-only.) Here again, the `upper` argument must not
    # be a shared layer/filter.
    for (key,val) in lower.sTab.pairs:
      if not upper.sTab.hasKey(key):
        upper.sTab[key] = val
    result = upper

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
