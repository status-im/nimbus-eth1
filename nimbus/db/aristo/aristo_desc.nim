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
## These data structures allows to overlay the *Patricia Trie* with *Merkel
## Trie* hashes. See the `README.md` in the `aristo` folder for documentation.
##
## Some semantic explanations;
##
## * HashKey, NodeRef etc. refer to the standard/legacy `Merkle Patricia Tree`
## * VertexID, VertexRef, etc. refer to the `Aristo Trie`
##
{.push raises: [].}

import
  std/[sets, tables],
  eth/common,
  ./aristo_constants,
  ./aristo_desc/[
    aristo_error, aristo_types_backend,
    aristo_types_identifiers, aristo_types_structural]

export
  # Not auto-exporting backend
  aristo_constants, aristo_error, aristo_types_identifiers,
  aristo_types_structural

type
  AristoLayerRef* = ref object
    ## Hexary trie database layer structures. Any layer holds the full
    ## change relative to the backend.
    sTab*: Table[VertexID,VertexRef] ## Structural vertex table
    lTab*: Table[LeafTie,VertexID]   ## Direct access, path to leaf vertex
    kMap*: Table[VertexID,HashLabel] ## Merkle hash key mapping
    dKey*: HashSet[VertexID]         ## Locally deleted Merkle hash keys
    pAmk*: Table[HashLabel,VertexID] ## Reverse mapper for data import
    pPrf*: HashSet[VertexID]         ## Locked vertices (proof nodes)
    vGen*: seq[VertexID]             ## Unique vertex ID generator

  AristoDb* = object
    ## Set of database layers, supporting transaction frames
    top*: AristoLayerRef             ## Database working layer
    stack*: seq[AristoLayerRef]      ## Stashed parent layers
    backend*: AristoBackendRef       ## Backend database (may well be `nil`)

    # Debugging data below, might go away in future
    xMap*: Table[HashLabel,VertexID] ## For pretty printing, extends `pAmk`

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

proc getOrVoid*[W](tab: Table[W,HashLabel]; w: W): HashLabel =
  tab.getOrDefault(w, VOID_HASH_LABEL)

proc getOrVoid*[W](tab: Table[W,VertexID]; w: W): VertexID =
  tab.getOrDefault(w, VertexID(0))

# --------

proc isValid*(vtx: VertexRef): bool =
  vtx != VertexRef(nil) 

proc isValid*(nd: NodeRef): bool =
  nd != NodeRef(nil)

proc isValid*(key: HashKey): bool =
  key != VOID_HASH_KEY

proc isValid*(lbl: HashLabel): bool =
  lbl != VOID_HASH_LABEL

proc isValid*(vid: VertexID): bool =
  vid != VertexID(0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
