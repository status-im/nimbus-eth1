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

proc deltaReverse*(
    db: KvtDbRef;                      # Database
    delta: LayerRef;                   # Filter to revert
      ): LayerRef =
  ## Assemble a reverse filter for the `delta` argument, i.e. changes to the
  ## backend that reverse the effect of applying this to the balancer filter.
  ## The resulting filter is calculated against the current *unfiltered*
  ## backend (excluding optionally installed balancer filters.)
  ##
  ## If `delta` is `nil`, the result will be `nil` as well.
  if not delta.isNil:
    result = LayerRef()

    # Calculate reverse changes for the `sTab[]` structural table
    for key in delta.sTab.keys:
      let rc = db.getUbe key
      if rc.isOk:
        result.sTab[key] = rc.value
      else:
        doAssert rc.error == GetNotFound
        result.sTab[key] = EmptyBlob

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
