# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/[hashes, tables],
  ./kvt_constants,
  ./kvt_desc/[desc_error, desc_structural]

from ./kvt_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  hashes, tables, kvt_constants, desc_error, desc_structural

type
  KvtTxRef* = ref object
    ## Transaction descriptor
    db*: KvtDbRef                     ## Database descriptor
    parent*: KvtTxRef                 ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  KvtDbRef* = ref object of RootRef
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    balancer*: LayerRef               ## Balance out concurrent backend access
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: KvtTxRef                  ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator

    # Debugging data below, might go away in future
    xIdGen*: uint64
    xMap*: Table[seq[byte],uint64]    ## For pretty printing
    pAmx*: Table[uint64,seq[byte]]    ## For pretty printing

  KvtDbAction* = proc(db: KvtDbRef) {.gcsafe, raises: [].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*(tab: Table[seq[byte],seq[byte]]; w: seq[byte]): seq[byte] =
  tab.getOrDefault(w, EmptyBlob)

func isValid*(key: seq[byte]): bool =
  key != EmptyBlob

func isValid*(layer: LayerRef): bool =
  layer != LayerRef(nil)

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: KvtDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# ------------------------------------------------------------------------------
# Public functions, `dude` related
# ------------------------------------------------------------------------------

iterator rstack*(db: KvtDbRef): LayerRef =
  # Stack in reverse order
  for i in 0..<db.stack.len:
    yield db.stack[db.stack.len - i - 1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
