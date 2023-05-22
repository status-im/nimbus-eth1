# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
## These data structures allows to overlay the *Patricia Trie* with *Merkel
## Trie* hashes. See the `README.md` in the `aristo` folder for documentation.
##
## Some semantic explanations;
##
## * NodeKey, NodeRef etc. refer to the standard/legacy `Merkel Patricia Tree`
## * VertexID, VertexRef, etc. refer to the `Aristo Trie`
##
{.push raises: [].}

import
  std/[sets, tables],
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/snap/range_desc,
  ./aristo_error

type
  VertexID* = distinct uint64
    ## Tip of edge towards child object in the `Patricia Trie` logic. It is
    ## also the key into the structural table of the `Aristo Trie`.

  GetVtxFn* =
    proc(vid: VertexID): Result[VertexRef,AristoError]
      {.gcsafe, raises: [].}
        ## Generic backend database retrieval function for a single structural
        ## `Aristo DB` data record.

  GetKeyFn* =
    proc(vid: VertexID): Result[NodeKey,AristoError]
      {.gcsafe, raises: [].}
        ## Generic backend database retrieval function for a single
        ## `Aristo DB` hash lookup value.

  PutVtxFn* =
    proc(vrps: openArray[(VertexID,VertexRef)]): AristoError
      {.gcsafe, raises: [].}
        ## Generic backend database bulk storage function.

  PutKeyFn* =
    proc(vkps: openArray[(VertexID,NodeKey)]): AristoError
      {.gcsafe, raises: [].}
        ## Generic backend database bulk storage function.

  DelFn* =
    proc(vids: openArray[VertexID])
      {.gcsafe, raises: [].}
        ## Generic backend database delete function for both, the structural
        ## `Aristo DB` data record and the hash lookup value.

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
    key*: array[16,NodeKey]          ## Merkle hash/es for Branch & Extension

  AristoBackendRef* = ref object
    ## Backend interface.
    getVtxFn*: GetVtxFn              ## Read vertex record
    getKeyFn*: GetKeyFn              ## Read vertex hash
    putVtxFn*: PutVtxFn              ## Bulk store vertex records
    putKeyFn*: PutKeyFn              ## Bulk store vertex hashes
    delFn*: DelFn                    ## Bulk delete vertex records and hashes

  AristoDbRef* = ref AristoDbObj
  AristoDbObj = object
    ## Hexary trie plus helper structures
    sTab*: Table[VertexID,VertexRef] ## Structural vertex table making up a trie
    lTab*: Table[NodeTag,VertexID]   ## Direct access, path to leaf node
    sDel*: HashSet[VertexID]         ## Deleted vertices
    kMap*: Table[VertexID,NodeKey]   ## Merkle hash key mapping
    pAmk*: Table[NodeKey,VertexID]   ## Reverse mapper for data import

    case cascaded*: bool             ## Cascaded delta databases, tx layer
    of true:
      level*: int                    ## Positive number of stack layers
      stack*: AristoDbRef            ## Down the chain, not `nil`
      base*: AristoDbRef             ## Backend level descriptor
    else:
      vidGen*: seq[VertexID]         ## Unique vertex ID generator
      backend*: AristoBackendRef     ## backend database (maybe `nil`)

    # Debugging data below, might go away in future
    xMap*: Table[NodeKey,VertexID]   ## For pretty printing, extends `pAmk`

static:
  # Not that there is no doubt about this ...
  doAssert NodeKey.default.ByteArray32.initNibbleRange.len == 64

# ------------------------------------------------------------------------------
# Public helpers: `VertexID` scalar data model
# ------------------------------------------------------------------------------

proc `<`*(a, b: VertexID): bool {.borrow.}
proc `==`*(a, b: VertexID): bool {.borrow.}
proc cmp*(a, b: VertexID): int {.borrow.}
proc `$`*(a: VertexID): string = $a.uint64

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

proc isZero*[T: NodeKey|VertexID](a: T): bool =
  a == typeof(a).default

proc isError*(a: NodeRef): bool =
  a.error != AristoError(0)

proc convertTo*(payload: PayloadRef; T: type Blob): T =
  ## Probably lossy conversion as the storage type `kind` gets missing
  case payload.pType:
  of BlobData:
    result = payload.blob
  of AccountData:
    result = rlp.encode payload.account

proc to*(node: NodeRef; T: type VertexRef): T =
  ## Extract a copy of the `VertexRef` part from a `NodeRef`. For a leaf
  ## type, the `lData` payload reference will be a shallow copy, i.e. only
  ## the reference pointer is copied.
  case node.vType:
  of Leaf:
    T(vType: Leaf,
      lPfx:  node.lPfx,
      lData: node.lData)
  of Extension:
    T(vType: Extension,
      ePfx:  node.ePfx,
      eVid:  node.eVid)
  of Branch:
    T(vType: Branch,
      bVid:  node.bVid)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
