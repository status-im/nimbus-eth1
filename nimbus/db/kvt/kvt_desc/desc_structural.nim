# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  LayerRef* = ref object
    ## Kvt database layer structures. Any layer holds the full
    ## change relative to the backend.
    tab*: Table[Blob,Blob]            ## Structural table
    txUid*: uint                      ## Transaction identifier if positive

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

proc dup*(layer: LayerRef): LayerRef =
  ## Duplicate layer.
  result = LayerRef(
    txUid: layer.txUid)
  for (k,v) in layer.tab.pairs:
    result.tab[k] = v

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
