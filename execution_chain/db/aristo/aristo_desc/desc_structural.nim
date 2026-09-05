# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  std/[bitops, hashes as std_hashes, strutils, tables],
  stint,
  eth/common/[accounts, base, hashes],
  ./desc_identifiers

export stint, tables, accounts, base, hashes

type
  VertexType* = enum
    ## Type of `Aristo Trie` vertex
    AccLeaf
    StoLeaf
    Branch
    ExtBranch
    BoundaryNode # Stateless only type
    LeafPtr # Root of a single-leaf trie, or a derived vid collision marker

  AristoAccount* = object
    ## Application relevant part of an Ethereum account. Note that the storage
    ## data/tree reference is not part of the account (see `LeafPayload` below.)
    nonce*:     AccountNonce         ## Some `uint64` type
    balance*:   UInt256
    codeHash*:  Hash32

  StorageID* = tuple
    ## Once a storage tree is allocated, its root vertex ID is registered in
    ## the leaf payload of an acoount. After subsequent storage tree deletion
    ## the root vertex ID will be kept in the leaf payload for re-use but set
    ## disabled (`.isValid` = `false`).
    isValid: bool                    ## See also `isValid()` for `VertexID`
    vid: VertexID                    ## Storage root vertex ID

  VertexRef* {.inheritable, pure.} = ref object
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    vType*: VertexType

  BranchRef* = ref object of VertexRef
    used*: uint16
      ## Bitmap of child slots in use
    leafMask*: uint16
      ## Subset of `used` whose children are leaves with an explicit vid
    startVid*: VertexID
      ## First vertex ID of the 16 slot block for branch children
    leafVids*: array[16, VertexID]
      ## Vertex IDs of the leaf children, indexed by nibble

  ExtBranchRef* = ref object of BranchRef
    pfx*: NibblesBuf

  BoundaryNodeRef* = ref object of VertexRef
    ## Stateless-only type. Represents a path prefix leading to an absent
    ## subtrie whose hash is known. Used in two scenarios:
    ##   1. Non-membership proof boundaries: `putSubtrie` puts a BoundaryNode
    ##      where the witness ends at a known hash but the subtrie is absent.
    ##   2. Branch collapse during delete: when a branch collapses to a single
    ##      nil vtx boundary child, the branch is replaced by a BoundaryNode
    ##      (prefix + boundary hash).
    ## Should never be created or used during full-node execution.
    pfx*: NibblesBuf
    childKey*: HashKey

  LeafPtrRef* = ref object of VertexRef
    ## Root record of a trie that consists of a single leaf, referring to the
    ## leaf by vid. With a zero vid it marks a derived vid that is shared by
    ## several leaves, all of which live at allocated vids.
    vid*: VertexID

  LeafRef* = ref object of VertexRef
    pfx*: NibblesBuf

  AccLeafRef* = ref object of LeafRef
    account*: AristoAccount
    stoID*: StorageID              ## Storage vertex ID (if any)

  StoLeafRef* = ref object of LeafRef
    stoData*: UInt256

  ## NOTE: Leaf cache values are stored as value types so the cache can be safely
  ## written from background pre-fetch threads under refc (which uses thread-local heaps).

  CachedAccLeaf* = object
    case empty*: bool
    of true:
      discard
    of false:
      pfx*: NibblesBuf
      account*: AristoAccount
      stoID*: StorageID

  CachedStoLeaf* = object
    pfx*: NibblesBuf
    stoData*: UInt256

  NodeRef* = ref object of RootRef
    ## Combined record for a *traditional* ``Merkle Patricia Tree` node merged
    ## with a structural `VertexRef` type object.
    vtx*: VertexRef
    key*: array[16, HashKey]          ## Merkle hash/es for vertices

  # ----------------------

  VidVtxPair* = object
    ## Handy helper structure
    vid*: VertexID                   ## Table lookup vertex ID (if any)
    vtx*: VertexRef                  ## Reference to vertex

  SavedState* = object
    ## Last saved state
    vTop*: VertexID                   ## Top used VertexID
    serial*: uint64                  ## Generic identifier from application
    derivedVids*: bool               ## All leaves reachable at their derived vid

  GetVtxFlag* = enum
    PeekCache
      ## Peek into, but don't update cache - useful on work loads that are
      ## unfriendly to caches

const
  Leaves* = {VertexType.AccLeaf, VertexType.StoLeaf}
  Branches* = {VertexType.Branch, VertexType.ExtBranch}
  VertexTypes* = Leaves + Branches + {VertexType.BoundaryNode, VertexType.LeafPtr}

# ------------------------------------------------------------------------------
# Public helpers (misc)
# ------------------------------------------------------------------------------

template init*(
    _: type AccLeafRef, pfxp: NibblesBuf, accountp: AristoAccount, stoIDp: StorageID
): AccLeafRef =
  AccLeafRef(vType: AccLeaf, pfx: pfxp, account: accountp, stoID: stoIDp)

template init*(_: type StoLeafRef, pfxp: NibblesBuf, stoDatap: UInt256): StoLeafRef =
  StoLeafRef(vType: StoLeaf, pfx: pfxp, stoData: stoDatap)

template init*(_: type BranchRef, startVidp: VertexID, usedp: uint16): BranchRef =
  BranchRef(vType: Branch, startVid: startVidp, used: usedp)

template init*(
    _: type ExtBranchRef, pfxp: NibblesBuf, startVidp: VertexID, usedp: uint16
): ExtBranchRef =
  ExtBranchRef(vType: ExtBranch, pfx: pfxp, startVid: startVidp, used: usedp)

template init*(_: type BoundaryNodeRef, pfxp: NibblesBuf, childKeyp: HashKey): BoundaryNodeRef =
  BoundaryNodeRef(vType: BoundaryNode, pfx: pfxp, childKey: childKeyp)

template init*(_: type LeafPtrRef, vidp: VertexID): LeafPtrRef =
  LeafPtrRef(vType: LeafPtr, vid: vidp)

template init*(
    T: type CachedAccLeaf, pfxp: NibblesBuf, accountp: AristoAccount, stoIDp: StorageID): T =
  T(empty: false, pfx: pfxp, account: accountp, stoID: stoIDp)

template init*(
    T: type CachedStoLeaf, pfxp: NibblesBuf, stoDatap: UInt256): T =
  T(pfx: pfxp, stoData: stoDatap)

const
  emptyCachedAccLeaf* = CachedAccLeaf(empty: true)
  emptyCachedStoLeaf* = CachedStoLeaf(stoData: 0.u256)

template isEmpty*(c: CachedAccLeaf): bool =
  c.empty

template isEmpty*(c: CachedStoLeaf): bool =
  c.stoData.isZero()

func toLeaf*(c: CachedAccLeaf): AccLeafRef =
  if c.isEmpty():
    AccLeafRef(nil)
  else:
    AccLeafRef.init(c.pfx, c.account, c.stoID)

func toLeaf*(c: CachedStoLeaf): StoLeafRef =
  if c.isEmpty():
    StoLeafRef(nil)
  else:
    StoLeafRef.init(c.pfx, c.stoData)

func toStoData*(c: CachedStoLeaf): UInt256 =
  c.stoData

func toStoData*(v: StoLeafRef): UInt256 =
  if v.isNil():
    0'u256
  else:
    v.stoData

const emptyNibbles = NibblesBuf()

template pfx*(vtx: VertexRef): NibblesBuf =
  case vtx.vType
  of Leaves:
    LeafRef(vtx).pfx
  of ExtBranch:
    ExtBranchRef(vtx).pfx
  of BoundaryNode:
    BoundaryNodeRef(vtx).pfx
  of Branch, LeafPtr:
    emptyNibbles

template pfx*(vtx: BranchRef): NibblesBuf =
  if vtx.vType == ExtBranch:
    ExtBranchRef(vtx).pfx
  else:
    emptyNibbles

template slotBit(nibble: uint8): uint16 =
  1'u16 shl nibble

func isUsed*(vtx: BranchRef, nibble: uint8): bool =
  (vtx.used and slotBit(nibble)) > 0

func isLeaf*(vtx: BranchRef, nibble: uint8): bool =
  (vtx.leafMask and slotBit(nibble)) > 0

func nChildren*(vtx: BranchRef): int =
  countSetBits(vtx.used)

func setLeaf*(vtx: BranchRef, nibble: uint8, vid: VertexID) =
  let bit = slotBit(nibble)
  vtx.leafVids[nibble] = vid
  vtx.leafMask = vtx.leafMask or bit
  vtx.used = vtx.used or bit

func clearSlot*(vtx: BranchRef, nibble: uint8) =
  let bit = slotBit(nibble)
  vtx.leafVids[nibble] = default(VertexID)
  vtx.leafMask = vtx.leafMask and not bit
  vtx.used = vtx.used and not bit

func setBranch*(vtx: BranchRef, nibble: uint8): VertexID =
  let bit = slotBit(nibble)
  vtx.leafVids[nibble] = default(VertexID)
  vtx.leafMask = vtx.leafMask and not bit
  vtx.used = vtx.used or bit
  VertexID(uint64(vtx.startVid) + nibble)

func bVid*(vtx: BranchRef, nibble: uint8): VertexID =
  let bit = slotBit(nibble)
  if (vtx.used and bit) == 0:
    default(VertexID)
  elif (vtx.leafMask and bit) > 0:
    vtx.leafVids[nibble]
  else:
    VertexID(uint64(vtx.startVid) + nibble)

func hash*(node: NodeRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](node).hash

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `VertexRef`
# ------------------------------------------------------------------------------

proc `==`*(a, b: VertexRef): bool =
  ## Beware, potential deep comparison
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false

  if unsafeAddr(a[]) != unsafeAddr(b[]):
    if a.vType != b.vType:
      return false
    case a.vType
    of AccLeaf:
      AccLeafRef(a)[] == AccLeafRef(b)[]
    of StoLeaf:
      StoLeafRef(a)[] == StoLeafRef(b)[]
    of Branch:
      BranchRef(a)[] == BranchRef(b)[]
    of ExtBranch:
      ExtBranchRef(a)[] == ExtBranchRef(b)[]
    of BoundaryNode:
      BoundaryNodeRef(a)[] == BoundaryNodeRef(b)[]
    of LeafPtr:
      LeafPtrRef(a)[] == LeafPtrRef(b)[]
  else:
    true

iterator pairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for other vertex types)
  case vtx.vType
  of Leaves, BoundaryNode, LeafPtr:
    discard
  of Branches:
    let vtx = BranchRef(vtx)
    for n in 0'u8 .. 15'u8:
      if (vtx.used and (1'u16 shl n)) > 0:
        yield (n, vtx.bVid(n))

iterator allPairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for other vertex
  ## types) including currently unset nodes
  case vtx.vType
  of Leaves, BoundaryNode, LeafPtr:
    discard
  of Branches:
    let vtx = BranchRef(vtx)
    for n in 0'u8 .. 15'u8:
      yield (n, vtx.bVid(n))

iterator leafSlots*(vtx: BranchRef): tuple[nibble: uint8, vid: VertexID] =
  for n in 0'u8 .. 15'u8:
    if (vtx.leafMask and (1'u16 shl n)) > 0:
      yield (n, vtx.leafVids[n])

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potential deep comparison
  if a.vtx != b.vtx:
    return false
  case a.vtx.vType
  of Branch:
    for n in 0'u8..15'u8:
      if BranchRef(a.vtx).bVid(n) != VertexID(0):
        if a.key[n] != b.key[n]:
          return false
  else:
    discard
  true

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

func dup*(vtx: VertexRef): VertexRef =
  ## Duplicate vertex.
  # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
  if vtx.isNil:
    VertexRef(nil)
  else:
    case vtx.vType
    of AccLeaf:
      let vtx = AccLeafRef(vtx)
      AccLeafRef.init(vtx.pfx, vtx.account, vtx.stoID)
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      StoLeafRef.init(vtx.pfx, vtx.stoData)
    of Branch:
      let vtx = BranchRef(vtx)
      BranchRef(
        vType: Branch,
        used: vtx.used,
        leafMask: vtx.leafMask,
        startVid: vtx.startVid,
        leafVids: vtx.leafVids,
      )
    of ExtBranch:
      let vtx = ExtBranchRef(vtx)
      ExtBranchRef(
        vType: ExtBranch,
        pfx: vtx.pfx,
        used: vtx.used,
        leafMask: vtx.leafMask,
        startVid: vtx.startVid,
        leafVids: vtx.leafVids,
      )
    of BoundaryNode:
      let vtx = BoundaryNodeRef(vtx)
      BoundaryNodeRef.init(vtx.pfx, vtx.childKey)
    of LeafPtr:
      LeafPtrRef.init(LeafPtrRef(vtx).vid)

template dup*(vtx: StoLeafRef): StoLeafRef =
  StoLeafRef(VertexRef(vtx).dup())

template dup*(vtx: AccLeafRef): AccLeafRef =
  AccLeafRef(VertexRef(vtx).dup())

template dup*(vtx: BranchRef): BranchRef =
  BranchRef(VertexRef(vtx).dup())

template dup*(vtx: ExtBranchRef): ExtBranchRef =
  ExtBranchRef(VertexRef(vtx).dup())

template dup*(vtx: BoundaryNodeRef): BoundaryNodeRef =
  BoundaryNodeRef(VertexRef(vtx).dup())

template dup*(vtx: LeafPtrRef): LeafPtrRef =
  LeafPtrRef(VertexRef(vtx).dup())

func `$`*(aa: AristoAccount): string =
  $aa.nonce & "," & $aa.balance & "," &
    (if aa.codeHash == EMPTY_CODE_HASH: ""
    else: $aa.codeHash)

func `$`*(stoID: StorageID): string =
  if stoID.isValid:
    $stoID.vid
  else:
    $default(VertexID)

func `$`*(vtx: AccLeafRef): string =
  if vtx == nil:
    "A(nil)"
  else:
    "A(" & $vtx.pfx & ":" & $vtx.account & "," & $vtx.stoID & ")"

func `$`*(vtx: StoLeafRef): string =
  if vtx == nil:
    "S(nil)"
  else:
    "S(" & $vtx.pfx & ":" & $vtx.stoData & ")"

func `$`*(vtx: BranchRef): string =
  if vtx == nil:
    "B(nil)"
  else:
    "B(" & $vtx.startVid & "+" & toBin(BiggestInt(vtx.used), 16) & "/" &
      toBin(BiggestInt(vtx.leafMask), 16) & ")"

func `$`*(vtx: ExtBranchRef): string =
  if vtx == nil:
    "E(nil)"
  else:
    "E(" & $vtx.pfx & ":"  & $vtx.startVid & "+" & toBin(BiggestInt(vtx.used), 16) &
      "/" & toBin(BiggestInt(vtx.leafMask), 16) & ")"

func `$`*(vtx: BoundaryNodeRef): string =
  if vtx == nil:
    "BN(nil)"
  else:
    "BN(" & $vtx.pfx & ":" & $vtx.childKey & ")"

func `$`*(vtx: LeafPtrRef): string =
  if vtx == nil:
    "P(nil)"
  else:
    "P(" & $vtx.vid & ")"

func `$`*(vtx: VertexRef): string =
  if vtx == nil:
    "V(nil)"
  else:
    case vtx.vType
    of AccLeaf:
      $(AccLeafRef(vtx))
    of StoLeaf:
      $(StoLeafRef(vtx))
    of Branch:
      $(BranchRef(vtx))
    of ExtBranch:
      $(ExtBranchRef(vtx))
    of BoundaryNode:
      $(BoundaryNodeRef(vtx))
    of LeafPtr:
      $(LeafPtrRef(vtx))


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
