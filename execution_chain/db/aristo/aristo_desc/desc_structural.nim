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
  std/[hashes as std_hashes, strutils, tables],
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
    startVid*: VertexID

  ExtBranchRef* = ref object of BranchRef
    pfx*: NibblesBuf

  LeafRef* = ref object of VertexRef
    pfx*: NibblesBuf

  AccLeafRef* = ref object of LeafRef
    account*: AristoAccount
    stoID*: StorageID              ## Storage vertex ID (if any)

  StoLeafRef* = ref object of LeafRef
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

  GetVtxFlag* = enum
    PeekCache
      ## Peek into, but don't update cache - useful on work loads that are
      ## unfriendly to caches

const
  Leaves* = {VertexType.AccLeaf, VertexType.StoLeaf}
  Branches* = {VertexType.Branch, VertexType.ExtBranch}
  VertexTypes* = Leaves + Branches

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

const emptyNibbles = NibblesBuf()

# template used*(vtx: VertexRef): uint16 = BranchRef(vtx).used
# template startVid*(vtx: VertexRef): VertexID = BranchRef(vtx).startVid
template pfx*(vtx: VertexRef): NibblesBuf =
  case vtx.vType
  of Leaves:
    LeafRef(vtx).pfx
  of ExtBranch:
    ExtBranchRef(vtx).pfx
  of Branch:
    emptyNibbles

template pfx*(vtx: BranchRef): NibblesBuf =
  if vtx.vType == ExtBranch:
    ExtBranchRef(vtx).pfx
  else:
    emptyNibbles

func bVid*(vtx: BranchRef, nibble: uint8): VertexID =
  if (vtx.used and (1'u16 shl nibble)) > 0:
    VertexID(uint64(vtx.startVid) + nibble)
  else:
    default(VertexID)

func setUsed*(vtx: BranchRef, nibble: uint8, used: static bool): VertexID =
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
  else:
    true

iterator pairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves)
  case vtx.vType
  of Leaves:
    discard
  of Branches:
    let vtx = BranchRef(vtx)
    for n in 0'u8 .. 15'u8:
      if (vtx.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.startVid) + n))

iterator allPairs*(vtx: VertexRef): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves) including
  ## currently unset nodes
  case vtx.vType
  of Leaves:
    discard
  of Branches:
    let vtx = BranchRef(vtx)
    for n in 0'u8 .. 15'u8:
      if (vtx.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.startVid) + n))
      else:
        yield (n, default(VertexID))

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
      BranchRef.init(vtx.startVid, vtx.used)
    of ExtBranch:
      let vtx = ExtBranchRef(vtx)
      ExtBranchRef.init(vtx.pfx, vtx.startVid, vtx.used)

template dup*(vtx: StoLeafRef): StoLeafRef =
  StoLeafRef(VertexRef(vtx).dup())

template dup*(vtx: AccLeafRef): AccLeafRef =
  AccLeafRef(VertexRef(vtx).dup())

template dup*(vtx: BranchRef): BranchRef =
  BranchRef(VertexRef(vtx).dup())

template dup*(vtx: ExtBranchRef): ExtBranchRef =
  ExtBranchRef(VertexRef(vtx).dup())

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
    "B(" & $vtx.startVid & "+" & toBin(BiggestInt(vtx.used), 16) & ")"

func `$`*(vtx: ExtBranchRef): string =
  if vtx == nil:
    "E(nil)"
  else:
    "E(" & $vtx.pfx & ":"  & $vtx.startVid & "+" & toBin(BiggestInt(vtx.used), 16) & ")"

func `$`*(vtx: VertexRef): string =
  if vtx == nil:
    "V(nil)"
  else:
    case vtx.vType
    of AccLeaf:
      $(AccLeafRef(vtx)[])
    of StoLeaf:
      $(StoLeafRef(vtx)[])
    of Branch:
      $(BranchRef(vtx)[])
    of ExtBranch:
      $(ExtBranchRef(vtx)[])


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
