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
  results,
  ".."/[kvt_desc, kvt_utils]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(
    db: KvtDbRef;                      # Database
    upper: LayerRef;                   # Filter to apply onto `lower`
    lower: var LayerRef;               # Target filter, will be modified
      ) =
  ## Merge the argument filter `upper` onto the argument filter `lower`
  ## relative to the *unfiltered* backend database on `db.backened`. The `lower`
  ## filter argument will have been modified.
  ##
  ## In case that the argument `lower` is `nil`, it will be replaced by `upper`.
  ##
  if lower.isNil:
    lower = upper
  elif not upper.isNil:
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
