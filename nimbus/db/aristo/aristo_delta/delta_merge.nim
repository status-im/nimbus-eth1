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
  ".."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deltaMerge*(
    upper: LayerRef;                   # Think of `top`, `nil` is ok
    lower: LayerRef;                   # Think of `balancer`, `nil` is ok
      ): LayerRef =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Note that the namimg `upper` and `lower` indicate that the filters are
  ## stacked and the database access is `upper -> lower -> backend`.
  ##
  if lower.isNil:
    # Degenerate case: `upper` is void
    upper

  elif upper.isNil:
    # Degenerate case: `lower` is void
    lower

  else:
    # Can modify `lower` which is the prefered action mode but applies only
    # in cases where the `lower` argument is not shared.
    lower.vTop = upper.vTop
    layersMergeOnto(upper, lower[])
    lower

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
