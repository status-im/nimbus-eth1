# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- a Patricia Trie with labeled edges
## ===============================================
##
## These data structures allow to overlay the *Patricia Trie* with *Merkel
## Trie* hashes. See the `README.md` in the `aristo` folder for documentation.
##
## Some semantic explanations;
##
## * HashKey, NodeRef etc. refer to the standard/legacy `Merkle Patricia Tree`
## * VertexID, VertexRef, etc. refer to the `Aristo Trie`
##
{.push raises: [].}

import
  std/[hashes, sets, tables],
  eth/common,
  ./aristo_constants,
  ./aristo_desc/[
    aristo_error, aristo_types_identifiers, aristo_types_structural]

from ./aristo_desc/aristo_types_backend
  import BackendRef

# Not auto-exporting backend
export
  aristo_constants, aristo_error, aristo_types_identifiers,
  aristo_types_structural

type
  AristoTxRef* = ref object
    ## Transaction descriptor
    db*: AristoDbRef                  ## Database descriptor
    parent*: AristoTxRef              ## Previous transaction
    txUid*: uint                      ## Unique ID among transactions
    level*: int                       ## Stack index for this transaction

  DudesRef* = ref object
    case rwOk*: bool
    of true:
      roDudes*: HashSet[AristoDbRef]  ## Read-only peers
    else:
      rwDb*: AristoDbRef              ## Link to writable descriptor

  AristoDbRef* = ref AristoDbObj
  AristoDbObj* = object
    ## Three tier database object supporting distributed instances.
    top*: LayerRef                    ## Database working layer, mutable
    stack*: seq[LayerRef]             ## Stashed immutable parent layers
    roFilter*: FilterRef              ## Apply read filter (locks writing)
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: AristoTxRef               ## Latest active transaction
    txUidGen*: uint                   ## Tx-relative unique number generator
    dudes*: DudesRef                  ## Related DB descriptors

    # Debugging data below, might go away in future
    xMap*: Table[HashLabel,VertexID]  ## For pretty printing, extends `pAmk`

  AristoDbAction* = proc(db: AristoDbRef) {.gcsafe, raises: [CatchableError].}
    ## Generic call back function/closure.

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

func getOrVoid*[W](tab: Table[W,HashLabel]; w: W): HashLabel =
  tab.getOrDefault(w, VOID_HASH_LABEL)

func getOrVoid*[W](tab: Table[W,HashKey]; w: W): HashKey =
  tab.getOrDefault(w, VOID_HASH_KEY)

func getOrVoid*[W](tab: Table[W,VertexID]; w: W): VertexID =
  tab.getOrDefault(w, VertexID(0))

# --------

func isValid*(vtx: VertexRef): bool =
  vtx != VertexRef(nil) 

func isValid*(nd: NodeRef): bool =
  nd != NodeRef(nil)

func isValid*(pld: PayloadRef): bool =
  pld != PayloadRef(nil)

func isValid*(filter: FilterRef): bool =
  filter != FilterRef(nil)

func isValid*(key: HashKey): bool =
  key != VOID_HASH_KEY

func isValid*(lbl: HashLabel): bool =
  lbl != VOID_HASH_LABEL

func isValid*(vid: VertexID): bool =
  vid != VertexID(0)

func isValid*(fid: FilterID): bool =
  fid != FilterID(0)

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: AristoDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# Note that the below `init()` function cannot go into
# `aristo_types_identifiers` as this would result in a circular import.
func init*(key: var HashKey; data: openArray[byte]): bool =
  ## Import argument `data` into `key` which must have length either `32`, or
  ## `0`. The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    (addr key.ByteArray32[0]).copyMem(unsafeAddr data[0], data.len)
    return true
  if data.len == 0:
    key = VOID_HASH_KEY
    return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
