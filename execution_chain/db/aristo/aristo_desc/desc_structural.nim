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
    Empty
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

  Vertex* = object
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    case vType*: VertexType
    of Empty:
      discard
    of Branch, ExtBranch:
      branch*: BranchData
    of AccLeaf:
      accLeaf*: AccLeafData
    of StoLeaf:
      stoLeaf*: StoLeafData

  NodeRef* = ref object of RootRef
    ## Combined record for a *traditional* ``Merkle Patricia Tree` node merged
    ## with a structural `Vertex` type object.
    vtx*: Vertex
    key*: array[16, HashKey]          ## Merkle hash/es for vertices

  BranchData* = object
    pfx*: Opt[NibblesBuf]
    startVid*: VertexID
    used*: uint16

  AccLeafData* = object
    pfx*: NibblesBuf
    account*: AristoAccount
    stoID*: StorageID

  StoLeafData* = object
    pfx*: NibblesBuf
    stoData*: UInt256

  # ----------------------

  VidVtxPair* = object
    ## Handy helper structure
    vid*: VertexID                   ## Table lookup vertex ID (if any)
    vtx*: Vertex                     ## Reference to vertex

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

template init*(_: type AccLeafData, pfxp: NibblesBuf, accountp: AristoAccount, stoIDp: StorageID): AccLeafData =
  AccLeafData(pfx: pfxp, account: accountp, stoID: stoIDp)

template init*(_: type StoLeafData, pfxp: NibblesBuf, stoDatap: UInt256): StoLeafData =
  StoLeafData(pfx: pfxp, stoData: stoDatap)

template init*(_: type BranchData, pfxp: Opt[NibblesBuf], startVidp: VertexID, usedp: uint16): BranchData =
  BranchData(pfx: pfxp, startVid: startVidp, used: usedp)

func initAccLeaf*(
    _: type Vertex, pfxp: NibblesBuf, accountp: AristoAccount, stoIDp: StorageID
): Vertex =
  Vertex(vType: AccLeaf, accLeaf: AccLeafData.init(pfxp, accountp, stoIDp))

func initStoLeaf*(_: type Vertex, pfxp: NibblesBuf, stoDatap: UInt256): Vertex =
  Vertex(vType: StoLeaf, stoLeaf: StoLeafData.init(pfxp, stoDatap))

func initBranch*(_: type Vertex, startVidp: VertexID, usedp: uint16): Vertex =
  Vertex(vType: Branch, branch: BranchData.init(Opt.none(NibblesBuf), startVidp, usedp))

func initExtBranch*(
    _: type Vertex, pfxp: NibblesBuf, startVidp: VertexID, usedp: uint16
): Vertex =
  Vertex(vType: ExtBranch, branch: BranchData.init(Opt.some(pfxp), startVidp, usedp))

const emptyNibbles = NibblesBuf()

const emptyVertex* = Vertex(vType: Empty)

template isEmpty*(vtx: Vertex): bool =
  vtx.vType == Empty

# template used*(vtx: Vertex): uint16 = BranchRef(vtx).used
# template startVid*(vtx: Vertex): VertexID = BranchRef(vtx).startVid
template pfx*(vtx: Vertex): NibblesBuf =
  case vtx.vType
  of Empty, Branch:
    emptyNibbles
  of ExtBranch:
    vtx.branch.pfx[]
  of AccLeaf:
    vtx.accLeaf.pfx
  of StoLeaf:
    vtx.stoLeaf.pfx

template pfx*(branch: BranchData): NibblesBuf =
  if branch.pfx.isSome():
    branch.pfx[]
  else:
    emptyNibbles

template pfx*(accLeaf: AccLeafData): NibblesBuf =
  accLeaf.pfx

template pfx*(stoLeaf: StoLeafData): NibblesBuf =
  stoLeaf.pfx

func bVid*(branch: BranchData, nibble: uint8): VertexID =
  if (branch.used and (1'u16 shl nibble)) > 0:
    VertexID(uint64(branch.startVid) + nibble)
  else:
    default(VertexID)

func setUsed*(branch: var BranchData, nibble: uint8, used: static bool): VertexID =
  branch.used =
    when used:
      branch.used or (1'u16 shl nibble)
    else:
      branch.used and (not (1'u16 shl nibble))
  branch.bVid(nibble)

func hash*(node: NodeRef): Hash =
  ## Table/KeyedQueue/HashSet mixin
  cast[pointer](node).hash

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `Vertex`
# ------------------------------------------------------------------------------

proc `==`*(a, b: Vertex): bool =
  ## Beware, potential deep comparison
  # if a.isNil:
  #   return b.isNil
  # if b.isNil:
  #   return false

  if unsafeAddr(a) != unsafeAddr(b):
    if a.vType != b.vType:
      return false
    case a.vType
    of Empty:
      true
    of AccLeaf:
      a.accLeaf == b.accLeaf
    of StoLeaf:
      a.stoLeaf == b.stoLeaf
    of Branch, ExtBranch:
      a.branch == b.branch
  else:
    true

iterator pairs*(vtx: Vertex): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves)
  case vtx.vType
  of Empty, Leaves:
    discard
  of Branches:
    for n in 0'u8 .. 15'u8:
      if (vtx.branch.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.branch.startVid) + n))

iterator allPairs*(vtx: Vertex): tuple[nibble: uint8, vid: VertexID] =
  ## Iterates over the sub-vids of a branch (does nothing for leaves) including
  ## currently unset nodes
  case vtx.vType
  of Empty, Leaves:
    discard
  of Branches:
    for n in 0'u8 .. 15'u8:
      if (vtx.branch.used and (1'u16 shl n)) > 0:
        yield (n, VertexID(uint64(vtx.branch.startVid) + n))
      else:
        yield (n, default(VertexID))

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potential deep comparison
  if a.vtx != b.vtx:
    return false
  case a.vtx.vType
  of Branch:
    for n in 0'u8..15'u8:
      if a.vtx.branch.bVid(n) != VertexID(0):
        if a.key[n] != b.key[n]:
          return false
  else:
    discard
  true

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

# func dup*(vtx: Vertex): Vertex =
#   ## Duplicate vertex.
#   # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
#   case vtx.vType
#   of Empty:
#     emptyVertex
#   of AccLeaf:
#     Vertex.initAccLeaf(vtx.accLeaf.pfx, vtx.accLeaf.account, vtx.accLeaf.stoID)
#   of StoLeaf:
#     Vertex.initStoLeaf(vtx.stoLeaf.pfx, vtx.stoLeaf.stoData)
#   of Branch:
#     Vertex.initBranch(vtx.branch.startVid, vtx.branch.used)
#   of ExtBranch:
#     Vertex.initExtBranch(vtx.branch.pfx[], vtx.branch.startVid, vtx.branch.used)

# template dup*(vtx: StoLeafData): StoLeafData =
#   StoLeafData(Vertex(vtx).dup())

# template dup*(vtx: AccLeafData): AccLeafData =
#   AccLeafData(Vertex(vtx).dup())

# template dup*(vtx: BranchRef): BranchRef =
#   BranchRef(Vertex(vtx).dup())

# template dup*(vtx: ExtBranchRef): ExtBranchRef =
#   ExtBranchRef(Vertex(vtx).dup())

func `$`*(aa: AristoAccount): string =
  $aa.nonce & "," & $aa.balance & "," &
    (if aa.codeHash == EMPTY_CODE_HASH: ""
    else: $aa.codeHash)

func `$`*(stoID: StorageID): string =
  if stoID.isValid:
    $stoID.vid
  else:
    $default(VertexID)

func `$`*(accLeaf: AccLeafData): string =
  "A(" & $accLeaf.pfx & ":" & $accLeaf.account & "," & $accLeaf.stoID & ")"

func `$`*(stoLeaf: StoLeafData): string =
  "S(" & $stoLeaf.pfx & ":" & $stoLeaf.stoData & ")"

func `$`*(branch: BranchData): string =
  "E(" & $branch.pfx & ":"  & $branch.startVid & "+" & toBin(BiggestInt(branch.used), 16) & ")"

func `$`*(vtx: Vertex): string =
  case vtx.vType
  of Empty:
    "V(empty)"
  of AccLeaf:
    $(vtx.accLeaf)
  of StoLeaf:
    $(vtx.stoLeaf)
  of Branch, ExtBranch:
    $(vtx.branch)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
