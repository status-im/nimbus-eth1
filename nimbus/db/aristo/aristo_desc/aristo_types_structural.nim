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
  eth/[common, trie/nibbles],
  "."/[aristo_error, aristo_types_identifiers]

type
  VertexType* = enum
    ## Type of `Aristo Trie` vertex
    Leaf
    Extension
    Branch

  PayloadType* = enum
    ## Type of leaf data (to be extended)
    BlobData                         ## Generic data, typically RLP encoded
    AccountData                      ## Legacy `Account` with hash references
    # AristoAccount                  ## `Aristo account` with vertex IDs links

  PayloadRef* = ref object
    case pType*: PayloadType
    of BlobData:
      blob*: Blob                    ## Opaque data value reference
    of AccountData:
      account*: Account              ## Expanded accounting data

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
    key*: array[16,HashKey]          ## Merkle hash/es for Branch & Extension

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
    of BlobData:
      if a.blob != b.blob:
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

proc convertTo*(payload: PayloadRef; T: type Blob): T =
  ## Probably lossy conversion as the storage type `kind` gets missing
  case payload.pType:
  of BlobData:
    result = payload.blob
  of AccountData:
    result = rlp.encode payload.account

proc dup*(pld: PayloadRef): PayloadRef =
  ## Duplicate payload.
  case pld.pType:
  of BlobData:
    PayloadRef(
      pType:    BlobData,
      blob:     pld.blob)
  of AccountData:
     PayloadRef(
       pType:   AccountData,
       account: pld.account)

proc dup*(vtx: VertexRef): VertexRef =
  ## Duplicate vertex.
  # Not using `deepCopy()` here (some `gc` needs `--deepcopy:on`.)
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

proc to*(node: NodeRef; T: type VertexRef): T =
  ## Extract a copy of the `VertexRef` part from a `NodeRef`.
  node.VertexRef.dup

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
