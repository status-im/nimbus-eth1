# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Handle vertex IDs on the layered Aristo DB delta architecture
## =============================================================
##
{.push raises: [].}

import
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoDbRef): VertexID =
  ## Fetch next vertex ID.
  ##
  if db.top.vTop  == 0:
    db.top.vTop = VertexID(LEAST_FREE_VID)
  else:
    db.top.vTop.inc
  db.top.vTop

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
