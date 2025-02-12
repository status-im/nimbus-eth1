# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- structural data types
## ===============================
##
{.push raises: [].}

import
  std/tables

export tables

type
  LayerRef* = ref Layer
  Layer* = object
    ## Kvt database layer structures. Any layer holds the full
    ## change relative to the backend.
    sTab*: Table[seq[byte],seq[byte]] ## Structural data table

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

func init*(T: type LayerRef): T =
  ## Constructor, returns empty layer
  T()

func dup*(ly: LayerRef): LayerRef =
  ## Duplicate/copy
  LayerRef(sTab: ly.sTab)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
