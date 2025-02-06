# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  eth/common/hashes,
  results,
  ./aristo_constants,
  ./aristo_desc/[desc_error, desc_identifiers, desc_nibbles, desc_structural],
  minilru


from ./aristo_desc/desc_backend
  import BackendRef

# Not auto-exporting backend
export
  tables, aristo_constants, desc_error, desc_identifiers, desc_nibbles,
  desc_structural, minilru, hashes

type
  AristoTxRef* = ref object
    ## Transaction descriptor
    db*: AristoDbRef                  ## Database descriptor
    parent*: AristoTxRef              ## Previous transaction
    layer*: LayerRef

  AristoDbRef* = ref object
    ## Three tier database object supporting distributed instances.
    backend*: BackendRef              ## Backend database (may well be `nil`)

    txRef*: AristoTxRef               ## Bottom-most in-memory frame

    accLeaves*: LruCache[Hash32, VertexRef]
      ## Account path to payload cache - accounts are frequently accessed by
      ## account path when contracts interact with them - this cache ensures
      ## that we don't have to re-traverse the storage trie for every such
      ## interaction
      ## TODO a better solution would probably be to cache this in a type
      ## exposed to the high-level API

    stoLeaves*: LruCache[Hash32, VertexRef]
      ## Mixed account/storage path to payload cache - same as above but caches
      ## the full lookup of storage slots

    # Debugging data below, might go away in future
    xMap*: Table[HashKey,RootedVertexID] ## For pretty printing/debugging

  Leg* = object
    ## For constructing a `VertexPath`
    wp*: VidVtxPair                ## Vertex ID and data ref
    nibble*: int8                  ## Next vertex selector for `Branch` (if any)

  Hike* = object
    ## Trie traversal path
    root*: VertexID                ## Handy for some fringe cases
    legs*: ArrayBuf[NibblesBuf.high + 1, Leg] ## Chain of vertices and IDs
    tail*: NibblesBuf              ## Portion of non completed path

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template mixUp*(accPath, stoPath: Hash32): Hash32 =
  # Insecure but fast way of mixing the values of two hashes, for the purpose
  # of quick lookups - this is certainly not a good idea for general Hash32
  # values but account paths are generated from accounts which would be hard
  # to create pre-images for, for the purpose of collisions with a particular
  # storage slot
  var v {.noinit.}: Hash32
  for i in 0..<v.data.len:
    # `+` wraps leaving all bits used
    v.data[i] = accPath.data[i] + stoPath.data[i]
  v

func getOrVoid*[W](tab: Table[W,VertexRef]; w: W): VertexRef =
  tab.getOrDefault(w, VertexRef(nil))

func getOrVoid*[W](tab: Table[W,NodeRef]; w: W): NodeRef =
  tab.getOrDefault(w, NodeRef(nil))

func getOrVoid*[W](tab: Table[W,HashKey]; w: W): HashKey =
  tab.getOrDefault(w, VOID_HASH_KEY)

func getOrVoid*[W](tab: Table[W,RootedVertexID]; w: W): RootedVertexID =
  tab.getOrDefault(w, default(RootedVertexID))

func getOrVoid*[W](tab: Table[W,HashSet[RootedVertexID]]; w: W): HashSet[RootedVertexID] =
  tab.getOrDefault(w, default(HashSet[RootedVertexID]))

# --------

func isValid*(vtx: VertexRef): bool =
  vtx != VertexRef(nil)

func isValid*(nd: NodeRef): bool =
  nd != NodeRef(nil)

func isValid*(pid: PathID): bool =
  pid != VOID_PATH_ID

func isValid*(layer: LayerRef): bool =
  layer != LayerRef(nil)

func isValid*(root: Hash32): bool =
  root != emptyRoot

func isValid*(key: HashKey): bool =
  assert key.len != 32 or key.to(Hash32).isValid
  0 < key.len

func isValid*(vid: VertexID): bool =
  vid != VertexID(0)

func isValid*(rvid: RootedVertexID): bool =
  rvid.vid.isValid and rvid.root.isValid

func isValid*(sqv: HashSet[RootedVertexID]): bool =
  sqv.len > 0

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Hash set helper
func hash*(db: AristoDbRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](db).hash

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

iterator rstack*(tx: AristoTxRef): (LayerRef, int) =
  # Stack in reverse order
  var tx = tx

  var i = 0
  while tx != nil:
    let level = if tx.parent == nil: -1 else: i
    yield (tx.layer, level)
    tx = tx.parent

proc deltaAtLevel*(db: AristoTxRef, level: int): LayerRef =
  if level == -2:
    nil
  elif level == -1:
    db.db.txRef.layer
  else:
    var
      frame = db
      level = level

    while level > 0:
      frame = frame.parent
      level -= 1

    frame.layer

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
