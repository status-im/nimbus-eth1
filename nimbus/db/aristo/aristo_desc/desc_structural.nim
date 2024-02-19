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

  PayloadRef* = ref object
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

  FilterRef* = ref object
    ## Delta layer with expanded sequences for quick access.
    fid*: FilterID                   ## Filter identifier
    src*: Hash256                    ## Applicable to this state root
    trg*: Hash256                    ## Resulting state root (i.e. `kMap[1]`)
    sTab*: Table[VertexID,VertexRef] ## Filter structural vertex table
    kMap*: Table[VertexID,HashKey]   ## Filter Merkle hash key mapping
    vGen*: seq[VertexID]             ## Filter unique vertex ID generator

  VidsByKeyTab* = Table[HashKey,HashSet[VertexID]]
    ## Reverse lookup searching `VertexID` by the hash key.

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
    sTab*: Table[VertexID,VertexRef] ## Structural vertex table
    kMap*: Table[VertexID,HashKey]   ## Merkle hash key mapping
    pAmk*: VidsByKeyTab              ## Reverse `kMap` entries, hash key lookup

  LayerFinalRef* = ref object
    ## Final tables fully supersede tables on lower layers when stacked as a
    ## whole. Missing entries on a higher layers are the final state (for the
    ## the top layer version of the table.)
    ##
    ## These structures are used for tables which are typically smaller then
    ## the ones on the `LayerDelta` object.
    ##
    pPrf*: HashSet[VertexID]         ## Locked vertices (proof nodes)
    vGen*: seq[VertexID]             ## Unique vertex ID generator
    dirty*: HashSet[VertexID]        ## Start nodes to re-hashiy from

  LayerRef* = ref LayerObj
  LayerObj* = object
    ## Hexary trie database layer structures. Any layer holds the full
    ## change relative to the backend.
    delta*: LayerDeltaRef            ## Most structural tables held as deltas
    final*: LayerFinalRef            ## Stored as latest version
    txUid*: uint                     ## Transaction identifier if positive

  # ----------------------

  QidLayoutRef* = ref object
    ## Layout of cascaded list of filter ID slot queues where a slot queue
    ## with index `N+1` serves as an overflow queue of slot queue `N`.
    q*: array[4,QidSpec]

  QidSpec* = tuple
    ## Layout of a filter ID slot queue
    size: uint                     ## Capacity of queue, length within `1..wrap`
    width: uint                    ## Instance gaps (relative to prev. item)
    wrap: QueueID                  ## Range `1..wrap` for round-robin queue

  QidSchedRef* = ref object of RootRef
    ## Current state of the filter queues
    ctx*: QidLayoutRef             ## Organisation of the FIFO
    state*: seq[(QueueID,QueueID)] ## Current fill state

const
  DefaultQidWrap = QueueID(0x3fff_ffff_ffff_ffffu64)

  QidSpecSizeMax* = high(uint32).uint
    ## Maximum value allowed for a `size` value of a `QidSpec` object

  QidSpecWidthMax* = high(uint32).uint
    ## Maximum value allowed for a `width` value of a `QidSpec` object

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func max(a, b, c: int): int =
  max(max(a,b),c)

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `PayloadRef`
# ------------------------------------------------------------------------------

func init*(T: type LayerRef): T =
  ## Constructor, returns empty layer
  T(delta: LayerDeltaRef(),
    final: LayerFinalRef())

func hash*(node: NodeRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](node).hash

# ---------------

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
    vGen:  final.vGen,
    dirty: final.dirty)

# ---------------

func to*(node: NodeRef; T: type VertexRef): T =
  ## Extract a copy of the `VertexRef` part from a `NodeRef`.
  node.VertexRef.dup

func to*(a: array[4,tuple[size, width: int]]; T: type QidLayoutRef): T =
  ## Convert a size-width array to a `QidLayoutRef` layout. Over large
  ## array field values are adjusted to its maximal size.
  var q: array[4,QidSpec]
  for n in 0..3:
    q[n] = (min(a[n].size.uint, QidSpecSizeMax),
            min(a[n].width.uint, QidSpecWidthMax),
            DefaultQidWrap)
  q[0].width = 0
  T(q: q)

func to*(a: array[4,tuple[size, width, wrap: int]]; T: type QidLayoutRef): T =
  ## Convert a size-width-wrap array to a `QidLayoutRef` layout. Over large
  ## array field values are adjusted to its maximal size. Too small `wrap`
  ## values are adjusted to its minimal size.
  var q: array[4,QidSpec]
  for n in 0..2:
    q[n] = (min(a[n].size.uint, QidSpecSizeMax),
            min(a[n].width.uint, QidSpecWidthMax),
            QueueID(max(a[n].size + a[n+1].width, a[n].width+1, a[n].wrap)))
  q[0].width = 0
  q[3] = (min(a[3].size.uint, QidSpecSizeMax),
          min(a[3].width.uint, QidSpecWidthMax),
          QueueID(max(a[3].size, a[3].width, a[3].wrap)))
  T(q: q)

# ------------------------------------------------------------------------------
# Public constructors for filter slot scheduler state
# ------------------------------------------------------------------------------

func init*(T: type QidSchedRef; a: array[4,(int,int)]): T =
  ## Constructor, see comments at the coverter function `to()` for adjustments
  ## of the layout argument `a`.
  T(ctx: a.to(QidLayoutRef))

func init*(T: type QidSchedRef; a: array[4,(int,int,int)]): T =
  ## Constructor, see comments at the coverter function `to()` for adjustments
  ## of the layout argument `a`.
  T(ctx: a.to(QidLayoutRef))

func init*(T: type QidSchedRef; ctx: QidLayoutRef): T =
  T(ctx: ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
