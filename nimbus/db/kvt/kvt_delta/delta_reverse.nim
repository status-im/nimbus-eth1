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

proc revFilter*(
    db: KvtDbRef;                      # Database
    filter: LayerRef;                  # Filter to revert
      ): Result[LayerRef,(seq[byte],KvtError)] =
  ## Assemble reverse filter for the `filter` argument, i.e. changes to the
  ## backend that reverse the effect of applying the this read-only filter.
  ##
  ## This read-only filter is calculated against the current unfiltered
  ## backend (excluding optionally installed read-only filter.)
  ##
  let rev = LayerRef()

  # Calculate reverse changes for the `sTab[]` structural table
  for key in filter.sTab.keys:
    let rc = db.getUbe key
    if rc.isOk:
      rev.sTab[key] = rc.value
    elif rc.error == GetNotFound:
      rev.sTab[key] = EmptyBlob
    else:
      return err((key,rc.error))

  ok(rev)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
