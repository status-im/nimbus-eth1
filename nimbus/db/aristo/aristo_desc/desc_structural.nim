# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie structural data types
## ================================================
##

{.push raises: [].}

import
  std/[hashes, tables],
  stint,
  eth/common,
  ./desc_identifiers

export stint

type
  LeafTiePayload* = object
    ## Generalised key-value pair for a sub-trie. The main trie is the
    ## sub-trie with `root=VertexID(1)`.
    leafTie*: LeafTie                ## Full `Patricia Trie` path root-to-leaf
    payload*: LeafPayload             ## Leaf data payload (see below)

  VertexType* = enum
    ## Type of `Aristo Trie` vertex
    Leaf
    Branch

  AristoAccount* = object
    ## Application relevant part of an Ethereum account. Note that the storage
    ## data/tree reference is not part of the account (see `LeafPayload` below.)
    nonce*:     AccountNonce         ## Some `uint64` type
    balance*:   UInt256
    codeHash*:  Hash32

  PayloadType* = enum
    ## Type of leaf data.
    AccountData                      ## `Aristo account` with vertex IDs links
    StoData                          ## Slot storage data

  StorageID* = tuple
    ## Once a storage tree is allocated, its root vertex ID is registered in
    ## the leaf payload of an acoount. After subsequent storage tree deletion
    ## the root vertex ID will be kept in the leaf payload for re-use but set
    ## disabled (`.isValid` = `false`).
    isValid: bool                    ## See also `isValid()` for `VertexID`
    vid: VertexID                    ## Storage root vertex ID

  LeafPayload* = object
    ## The payload type depends on the sub-tree used. The `VertexID(1)` rooted
    ## sub-tree only has `AccountData` type payload, stoID-based have StoData
    case pType*: PayloadType
    of AccountData:
      account*: AristoAccount
      stoID*: StorageID              ## Storage vertex ID (if any)
    of StoData:
      stoData*: UInt256

  VertexRef* = ref object
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    pfx*: NibblesBuf
      ## Portion of path segment - extension nodes are branch nodes with
      ## non-empty prefix
    case vType*: VertexType
    of Leaf:
      lData*: LeafPayload            ## Reference to data payload
    of Branch:
      bVid*: array[16,VertexID]      ## Edge list with vertex IDs

  NodeRef* = ref object of RootRef
    ## Combined record for a *traditional* ``Merkle Patricia Tree` node merged
    ## with a structural `VertexRef` type object.
    vtx*: VertexRef
    key*: array[16,HashKey]          ## Merkle hash/es for vertices

  # ----------------------

  VidVtxPair* = object
    ## Handy helper structure
    vid*: VertexID                   ## Table lookup vertex ID (if any)
    vtx*: VertexRef                  ## Reference to vertex

  SavedState* = object
    ## Last saved state
    key*: Hash32                     ## Some state hash (if any)
    serial*: uint64                  ## Generic identifier from application

  LayerRef* = ref LayerObj
  LayerObj* = object
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
    ##
    sTab*: Table[RootedVertexID,VertexRef] ## Structural vertex table
    kMap*: Table[RootedVertexID,HashKey]   ## Merkle hash key mapping
    vTop*: VertexID                        ## Last used vertex ID

    accLeaves*: Table[Hash32, VertexRef]   ## Account path -> VertexRef
    stoLeaves*: Table[Hash32, VertexRef]   ## Storage path -> VertexRef

    txUid*: uint                           ## Transaction identifier if positive

  GetVtxFlag* = enum
    PeekCache
      ## Peek into, but don't update cache - useful on work loads that are
      ## unfriendly to caches

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

func init*(T: type LayerRef): T =
  ## Constructor, returns empty layer
  T()

func hash*(node: NodeRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](node).hash

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `LeafPayload`
# ------------------------------------------------------------------------------

proc `==`*(a, b: LeafPayload): bool =
  ## Beware, potential deep comparison
  if unsafeAddr(a) != unsafeAddr(b):
    if a.pType != b.pType:
      return false
    case a.pType:
    of AccountData:
      if a.account != b.account or
         a.stoID != b.stoID:
        return false
    of StoData:
      if a.stoData != b.stoData:
        return false
  true

proc `==`*(a, b: VertexRef): bool =
  ## Beware, potential deep comparison
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a[]) != unsafeAddr(b[]):
    if a.vType != b.vType:
      return false
    case a.vType:
    of Leaf:
      if a.pfx != b.pfx or a.lData != b.lData:
        return false
    of Branch:
      if a.pfx != b.pfx or a.bVid != b.bVid:
        return false
  true

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potential deep comparison
  if a.vtx != b.vtx:
    return false
  case a.vtx.vType:
  of Branch:
    for n in 0..15:
      if a.vtx.bVid[n] != 0.VertexID or b.vtx.bVid[n] != 0.VertexID:
        if a.key[n] != b.key[n]:
          return false
  else:
    discard
  true

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

func dup*(pld: LeafPayload): LeafPayload =
  ## Duplicate payload.
  case pld.pType:
  of AccountData:
    LeafPayload(
      pType:   AccountData,
      account: pld.account,
      stoID:   pld.stoID)
  of StoData:
    LeafPayload(
      pType:   StoData,
      stoData: pld.stoData
    )

func dup*(vtx: VertexRef): VertexRef =
  ## Duplicate vertex.
  # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
  if vtx.isNil:
    VertexRef(nil)
  else:
    case vtx.vType:
    of Leaf:
      VertexRef(
        vType: Leaf,
        pfx:   vtx.pfx,
        lData: vtx.lData.dup)
    of Branch:
      VertexRef(
        vType: Branch,
        pfx:   vtx.pfx,
        bVid:  vtx.bVid)

func dup*(node: NodeRef): NodeRef =
  ## Duplicate node.
  # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
  if node.isNil:
    NodeRef(nil)
  else:
    NodeRef(
      vtx: node.vtx.dup(),
      key:   node.key)

func dup*(wp: VidVtxPair): VidVtxPair =
  ## Safe copy of `wp` argument
  VidVtxPair(
    vid: wp.vid,
    vtx: wp.vtx.dup)

# ---------------

func to*(node: NodeRef; T: type VertexRef): T =
  ## Extract a copy of the `VertexRef` part from a `NodeRef`.
  node.VertexRef.dup

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
