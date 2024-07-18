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
  ".."/[kvt_desc, kvt_utils]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc deltaMerge*(
    db: KvtDbRef;                      # Database
    upper: LayerRef;                   # Filter to apply onto `lower`
    lower: LayerRef;                   # Target filter, will be modified
      ): Result[LayerRef,(Blob,KvtError)] =
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
  let newFilter = LayerRef(sTab: lower.sTab)

  for (key,val) in upper.sTab.pairs:
    if val.isValid or not lower.sTab.hasKey key:
      lower.sTab[key] = val
    elif lower.sTab.getOrVoid(key).isValid:
      let rc = db.getUbe key
      if rc.isOk:
        lower.sTab[key] = val # empty blob
      else:
        doAssert rc.error == GetNotFound
        lower.sTab.del key # no need to keep that in merged filter

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
