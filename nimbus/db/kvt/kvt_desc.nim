# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- key-value table
## =========================
##
{.push raises: [].}

import
  std/tables,
  eth/common,
  ./kvt_constants,
  ./kvt_desc/[desc_error, desc_structural]

from ./kvt_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  kvt_constants, desc_error, desc_structural

type
  KvtTxRef* = ref object
    ## Transaction descriptor
    db*: KvtDbRef                     ## Database descriptor
    parent*: KvtTxRef                 ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  KvtDbRef* = ref KvtDbObj
  KvtDbObj* = object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: KvtTxRef                  ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator

  KvtDbAction* = proc(db: KvtDbRef) {.gcsafe, raises: [CatchableError].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*(tab: Table[Blob,Blob]; w: Blob): Blob =
  tab.getOrDefault(w, EmptyBlob)

func isValid*(key: Blob): bool =
  key != EmptyBlob

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
