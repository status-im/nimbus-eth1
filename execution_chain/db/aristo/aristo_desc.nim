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
  import BackendRef, PutHdlRef

# Not auto-exporting backend
export
  tables, aristo_constants, desc_error, desc_identifiers, desc_nibbles,
  desc_structural, minilru, hashes, PutHdlRef

type
  AristoTxRef* = ref object
    ## Transaction descriptor
    ##
    ## Delta layers are stacked implying a tables hierarchy. Table entries on
    ## a higher level take precedence over lower layer table entries. So an
    ## existing key-value table entry of a layer on top supersedes same key
    ## entries on all lower layers. A missing entry on a higher layer indicates
    ## that the key-value pair might be fond on some lower layer.
    ##
    ## A zero value (`nil`, empty hash etc.) is considered am missing key-value
    ## pair. Tables on the `LayerDelta` may have stray zero key-value pairs for
    ## missing entries due to repeated transactions while adding and deleting
    ## entries. There is no need to purge redundant zero entries.
    ##
    ## As for `kMap[]` entries, there might be a zero value entriy relating
    ## (i.e. indexed by the same vertex ID) to an `sMap[]` non-zero value entry
    ## (of the same layer or a lower layer whatever comes first.) This entry
    ## is kept as a reminder that the hash value of the `kMap[]` entry needs
    ## to be re-compiled.
    ##
    ## The reasoning behind the above scenario is that every vertex held on the
    ## `sTab[]` tables must correspond to a hash entry held on the `kMap[]`
    ## tables. So a corresponding zero value or missing entry produces an
    ## inconsistent state that must be resolved.

    db*: AristoDbRef                  ## Database descriptor
    parent*: AristoTxRef              ## Previous transaction

    sTab*: Table[RootedVertexID,VertexRef] ## Structural vertex table
    kMap*: Table[RootedVertexID,HashKey]   ## Merkle hash key mapping
    vTop*: VertexID                        ## Last used vertex ID

    accLeaves*: Table[Hash32, VertexRef]   ## Account path -> VertexRef
    stoLeaves*: Table[Hash32, VertexRef]   ## Storage path -> VertexRef

    cTop*: VertexID                        ## Last committed vertex ID

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

func isValid*(tx: AristoTxRef): bool =
  tx != AristoTxRef(nil)

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

iterator rstack*(tx: AristoTxRef): (AristoTxRef, int) =
  # Stack in reverse order
  var tx = tx

  var i = 0
  while tx != nil:
    let level = if tx.parent == nil: -1 else: i
    yield (tx, level)
    tx = tx.parent

proc deltaAtLevel*(db: AristoTxRef, level: int): AristoTxRef =
  if level == -2:
    nil
  elif level == -1:
    db.db.txRef
  else:
    var
      frame = db
      level = level

    while level > 0:
      frame = frame.parent
      level -= 1

    frame

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
