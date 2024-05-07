# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  std/tables,
  eth/common

type
  LayerDeltaRef* = ref object
    ## Delta tables relative to previous layer
    sTab*: Table[Blob,Blob]           ## Structural data table

  LayerRef* = ref object
    ## Kvt database layer structures. Any layer holds the full
    ## change relative to the backend.
    delta*: LayerDeltaRef             ## Structural tables held as deltas
    txUid*: uint                      ## Transaction identifier if positive

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

func init*(T: type LayerRef): T =
  ## Constructor, returns empty layer
  T(delta: LayerDeltaRef())

func dup*(ly: LayerDeltaRef): LayerDeltaRef =
  ## Duplicate/copy
  LayerDeltaRef(sTab: ly.sTab)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
