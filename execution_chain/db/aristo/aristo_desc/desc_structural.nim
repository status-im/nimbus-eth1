# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  std/[hashes as std_hashes, tables],
  stint,
  eth/common/[accounts, base, hashes],
  ./desc_identifiers

export stint, tables, accounts, base, hashes

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
      startVid*: VertexID
      used*: uint16

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

  GetVtxFlag* = enum
    PeekCache
      ## Peek into, but don't update cache - useful on work loads that are
      ## unfriendly to caches

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

func bVid*(vtx: VertexRef, nibble: uint8): VertexID =
  if (vtx.used and (1'u16 shl nibble)) > 0:
    VertexID(uint64(vtx.startVid) + nibble)
  else:
    default(VertexID)

func setUsed*(vtx: VertexRef, nibble: uint8, used: static bool): VertexID =
  vtx.used =
    when used:
      vtx.used or (1'u16 shl nibble)
    else:
      vtx.used and (not (1'u16 shl nibble))
  vtx.bVid(nibble)

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
      if a.pfx != b.pfx or a.startVid != b.startVid or a.used != b.used:
        return false
  true

iterator pairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves)
  case vtx.vType:
  of Leaf:
    discard
  of Branch:
    for n in 0'u8 .. 15'u8:
      if (vtx.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.startVid) + n))

iterator allPairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves) including
  ## currently unset nodes
  case vtx.vType:
  of Leaf:
    discard
  of Branch:
    for n in 0'u8 .. 15'u8:
      if (vtx.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.startVid) + n))
      else:
        yield (n, default(VertexID))

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potential deep comparison
  if a.vtx != b.vtx:
    return false
  case a.vtx.vType:
  of Branch:
    for n in 0'u8..15'u8:
      if a.vtx.bVid(n) != 0.VertexID or b.vtx.bVid(n) != 0.VertexID:
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
        startVid: vtx.startVid,
        used: vtx.used)

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
