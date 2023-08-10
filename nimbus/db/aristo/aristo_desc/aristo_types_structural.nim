# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  std/[options, sets, tables],
  eth/[common, trie/nibbles],
  "."/[aristo_error, aristo_types_identifiers]

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
    ## Type of leaf data. On the Aristo backend, data are serialised as
    ## follows:
    ##
    ## * Opaque data => opaque data, marked `0xff`
    ## * `Account` object => RLP encoded data, marked `0xaa`
    ## * `AristoAccount` object => serialised account, marked `0x99` or smaller
    ##
    ## On deserialisation from the Aristo backend, there is no reverese for an
    ## `Account` object. It rather is kept as an RLP encoded `Blob`.
    ##
    ## * opaque data, marked `0xff` => `RawData`
    ## * RLP encoded data, marked `0xaa` => `RlpData`
    ## * erialised account, marked `0x99` or smaller => `AccountData`
    ##
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
    error*: AristoError              ## Can be used for error signalling
    key*: array[16,HashKey]          ## Merkle hash/es for vertices

  # ----------------------

  AristoChangeLogRef* = ref object
    ## Change log: database state before backend saving.
    root*: HashKey                    ## Previous hash key for `VertexID(1)`
    leafs*: Table[LeafTie,PayloadRef] ## Changed leafs after merge into backend

  AristoFilterRef* = ref object
    ## Delta layer with expanded sequences for quick access
    src*: HashKey                    ## Applicable to this state root
    sTab*: Table[VertexID,VertexRef] ## Filter structural vertex table
    kMap*: Table[VertexID,HashKey]   ## Filter Merkle hash key mapping
    vGen*: Option[seq[VertexID]]     ## Filter unique vertex ID generator
    trg*: HashKey                    ## Resulting state root (i.e. `kMap[1]`)

  AristoLayerRef* = ref object
    ## Hexary trie database layer structures. Any layer holds the full
    ## change relative to the backend.
    sTab*: Table[VertexID,VertexRef]  ## Structural vertex table
    lTab*: Table[LeafTie,VertexID]    ## Direct access, path to leaf vertex
    kMap*: Table[VertexID,HashLabel]  ## Merkle hash key mapping
    pAmk*: Table[HashLabel,VertexID]  ## Reverse `kMap` entries, hash key lookup
    pPrf*: HashSet[VertexID]          ## Locked vertices (proof nodes)
    vGen*: seq[VertexID]              ## Unique vertex ID generator
    txUid*: uint                      ## Transaction identifier if positive

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

proc dup*(pld: PayloadRef): PayloadRef =
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

proc dup*(vtx: VertexRef): VertexRef =
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
        lData: vtx.ldata.dup)
    of Extension:
      VertexRef(
        vType: Extension,
        ePfx:  vtx.ePfx,
        eVid:  vtx.eVid)
    of Branch:
      VertexRef(
        vType: Branch,
        bVid:  vtx.bVid)

proc dup*(node: NodeRef): NodeRef =
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
        lData: node.ldata.dup,
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

proc dup*(layer: AristoLayerRef): AristoLayerRef =
  ## Duplicate layer.
  result = AristoLayerRef(
    lTab:  layer.lTab,
    kMap:  layer.kMap,
    pAmk:  layer.pAmk,
    pPrf:  layer.pPrf,
    vGen:  layer.vGen,
    txUid: layer.txUid)
  for (k,v) in layer.sTab.pairs:
    result.sTab[k] = v.dup

proc to*(node: NodeRef; T: type VertexRef): T =
  ## Extract a copy of the `VertexRef` part from a `NodeRef`.
  node.VertexRef.dup

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
