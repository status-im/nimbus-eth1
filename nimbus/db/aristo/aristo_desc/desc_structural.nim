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
  std/[hashes, sets, tables],
  eth/[common, trie/nibbles],
  "."/[desc_error, desc_identifiers]

type
  VertexType* = enum
    ## Type of `Aristo Trie` vertex
    Leaf
    Extension
    Branch

  AristoAccount* = object
    nonce*:     AccountNonce         ## Some `uint64` type
    balance*:   UInt256
    storageID*: VertexID             ## Implies storage root Merkle hash key
    codeHash*:  Hash256

  PayloadType* = enum
    ## Type of leaf data.
    RawData                          ## Generic data
    RlpData                          ## Marked RLP encoded
    AccountData                      ## `Aristo account` with vertex IDs links

  PayloadRef* = ref object of RootRef
    case pType*: PayloadType
    of RawData:
      rawBlob*: Blob                 ## Opaque data, default value
    of RlpData:
      rlpBlob*: Blob                 ## Opaque data marked RLP encoded
    of AccountData:
      account*: AristoAccount

  VertexRef* = ref object of RootRef
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    case vType*: VertexType
    of Leaf:
      lPfx*: NibblesSeq              ## Portion of path segment
      lData*: PayloadRef             ## Reference to data payload
    of Extension:
      ePfx*: NibblesSeq              ## Portion of path segment
      eVid*: VertexID                ## Edge to vertex with ID `eVid`
    of Branch:
      bVid*: array[16,VertexID]      ## Edge list with vertex IDs

  NodeRef* = ref object of VertexRef
    ## Combined record for a *traditional* ``Merkle Patricia Tree` node merged
    ## with a structural `VertexRef` type object.
    error*: AristoError              ## Used for error signalling in RLP decoder
    key*: array[16,HashKey]          ## Merkle hash/es for vertices

  # ----------------------

  VidVtxPair* = object
    ## Handy helper structure
    vid*: VertexID                    ## Table lookup vertex ID (if any)
    vtx*: VertexRef                   ## Reference to vertex

  SavedState* = object
    ## Last saved state
    src*: HashKey                    ## Previous state hash
    trg*: HashKey                    ## Last state hash
    serial*: uint64                  ## Generic identifier froom application

  LayerDeltaRef* = ref object
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
    src*: HashKey                    ## Only needed when used as a filter
    sTab*: Table[VertexID,VertexRef] ## Structural vertex table
    kMap*: Table[VertexID,HashKey]   ## Merkle hash key mapping
    vTop*: VertexID                  ## Last used vertex ID

  LayerFinalRef* = ref object
    ## Final tables fully supersede tables on lower layers when stacked as a
    ## whole. Missing entries on a higher layers are the final state (for the
    ## the top layer version of the table.)
    ##
    ## These structures are used for tables which are typically smaller then
    ## the ones on the `LayerDelta` object.
    ##
    pPrf*: HashSet[VertexID]         ## Locked vertices (proof nodes)
    fRpp*: Table[HashKey,VertexID]   ## Key lookup for `pPrf[]` (proof nodes)
    dirty*: HashSet[VertexID]        ## Start nodes to re-hashiy from

  LayerRef* = ref LayerObj
  LayerObj* = object
    ## Hexary trie database layer structures. Any layer holds the full
    ## change relative to the backend.
    delta*: LayerDeltaRef            ## Most structural tables held as deltas
    final*: LayerFinalRef            ## Stored as latest version
    txUid*: uint                     ## Transaction identifier if positive

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

func init*(T: type LayerRef): T =
  ## Constructor, returns empty layer
  T(delta: LayerDeltaRef(),
    final: LayerFinalRef())

func hash*(node: NodeRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](node).hash

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `PayloadRef`
# ------------------------------------------------------------------------------

proc `==`*(a, b: PayloadRef): bool =
  ## Beware, potential deep comparison
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a) != unsafeAddr(b):
    if a.pType != b.pType:
      return false
    case a.pType:
    of RawData:
      if a.rawBlob != b.rawBlob:
        return false
    of RlpData:
      if a.rlpBlob != b.rlpBlob:
        return false
    of AccountData:
      if a.account != b.account:
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
      if a.lPfx != b.lPfx or a.lData != b.lData:
        return false
    of Extension:
      if a.ePfx != b.ePfx or a.eVid != b.eVid:
        return false
    of Branch:
      for n in 0..15:
        if a.bVid[n] != b.bVid[n]:
          return false
  true

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potential deep comparison
  if a.VertexRef != b.VertexRef:
    return false
  case a.vType:
  of Extension:
    if a.key[0] != b.key[0]:
      return false
  of Branch:
    for n in 0..15:
      if a.bVid[n] != 0.VertexID and a.key[n] != b.key[n]:
        return false
  else:
    discard
  true

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

func dup*(pld: PayloadRef): PayloadRef =
  ## Duplicate payload.
  case pld.pType:
  of RawData:
    PayloadRef(
      pType:    RawData,
      rawBlob:  pld.rawBlob)
  of RlpData:
    PayloadRef(
      pType:    RlpData,
      rlpBlob:  pld.rlpBlob)
  of AccountData:
    PayloadRef(
      pType:   AccountData,
      account: pld.account)

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
        lPfx:  vtx.lPfx,
        lData: vtx.lData.dup)
    of Extension:
      VertexRef(
        vType: Extension,
        ePfx:  vtx.ePfx,
        eVid:  vtx.eVid)
    of Branch:
      VertexRef(
        vType: Branch,
        bVid:  vtx.bVid)

func dup*(node: NodeRef): NodeRef =
  ## Duplicate node.
  # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
  if node.isNil:
    NodeRef(nil)
  else:
    case node.vType:
    of Leaf:
      NodeRef(
        vType: Leaf,
        lPfx:  node.lPfx,
        lData: node.lData.dup,
        key:   node.key)
    of Extension:
      NodeRef(
        vType: Extension,
        ePfx:  node.ePfx,
        eVid:  node.eVid,
        key:   node.key)
    of Branch:
      NodeRef(
        vType: Branch,
        bVid:  node.bVid,
        key:   node.key)

func dup*(final: LayerFinalRef): LayerFinalRef =
  ## Duplicate final layer.
  LayerFinalRef(
    pPrf:  final.pPrf,
    fRpp:  final.fRpp,
    dirty: final.dirty)

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
