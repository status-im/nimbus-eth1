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

{.push raises: [].}

import
  std/tables,
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/snap/range_desc,
  ./aristo_error

type
  VertexID* = distinct uint64      ## Tip of edge towards child, also table key

  VertexType* = enum               ## Type of Patricia Trie node
    Leaf
    Extension
    Branch

  PayloadType* = enum              ## Type of leaf data (to be extended)
    BlobData
    AccountData

  PayloadRef* = ref object
    case pType*: PayloadType
    of BlobData:
      blob*: Blob                  ## Opaque data value reference
    of AccountData:
      account*: Account            ## Expanded accounting data

  VertexRef* = ref object of RootRef
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    case vType*: VertexType
    of Leaf:
      lPfx*: NibblesSeq            ## Portion of path segment
      lData*: PayloadRef           ## Reference to data payload
    of Extension:
      ePfx*: NibblesSeq            ## Portion of path segment
      eVid*: VertexID              ## Edge to vertex with ID `eVid`
    of Branch:
      bVid*: array[16,VertexID]    ## Edge list with vertex IDs

  NodeRef* = ref object of VertexRef
    ## Combined record for a *traditional* ``Merkle Patricia Tree` node merged
    ## with a structural `VertexRef` type object.
    error*: AristoError            ## Can be used for error signalling
    key*: array[16,NodeKey]        ## Merkle hash(es) for Branch & Extension vtx

  PathStep* = object
    ## For constructing a tree traversal path
    # key*: NodeKey                ## Node label ??
    node*: VertexRef               ## Referes to data record
    nibble*: int8                  ## Branch node selector (if any)
    depth*: int                    ## May indicate path length (typically 64)

  Path* = object
    root*: VertexID                ## Root node needed when `path.len == 0`
    path*: seq[PathStep]           ## Chain of nodes
    tail*: NibblesSeq              ## Stands for non completed leaf path

  LeafSpecs* = object
    ## Temporarily stashed leaf data (as for an account.) Proper records
    ## have non-empty payload. Records with empty payload are administrative
    ## items, e.g. lower boundary records.
    pathTag*: NodeTag              ## `Patricia Trie` key path
    nodeVid*: VertexID             ## Table lookup vertex ID (if any)
    payload*: PayloadRef           ## Reference to data payload

  GetFn* = proc(key: openArray[byte]): Blob
    {.gcsafe, raises: [CatchableError].}
      ## Persistent database `get()` function. For read-only cases, this
      ## function can be seen as the persistent alternative to ``tab[]` on
      ## a `HexaryTreeDbRef` descriptor.

  AristoDbRef* = ref object of RootObj
    ## Hexary trie plus helper structures
    sTab*: Table[VertexID,NodeRef] ## Structural vertex table making up a trie
    kMap*: Table[VertexID,NodeKey] ## Merkle hash key mapping
    pAmk*: Table[NodeKey,VertexID] ## Reverse mapper for data import
    vidGen*: seq[VertexID]         ## Unique vertex ID generator

    # Debugging data below, might go away in future
    xMap*: Table[NodeKey,VertexID] ## Mapper for pretty printing, extends `pAmk`

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
# Public functions for `VertexID` management
# ------------------------------------------------------------------------------

proc new*(T: type VertexID; db: AristoDbRef): T =
  ## Create a new `VertexID`. Reusable *ID*s are kept in a list where the top
  ## entry *ID0* has the property that any other *ID* larger *ID0* is also not
  ## not used on the database.
  case db.vidGen.len:
  of 0:
    db.vidGen = @[2.VertexID]
    result = 1.VertexID
  of 1:
    result = db.vidGen[^1]
    db.vidGen = @[(result.uint64 + 1).VertexID]
  else:
    result = db.vidGen[^2]
    db.vidGen[^2] = db.vidGen[^1]
    db.vidGen.setLen(db.vidGen.len-1)

proc peek*(T: type VertexID; db: AristoDbRef): T =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  if db.vidGen.len == 0: 1u64 else: db.vidGen[^1]


proc dispose*(db: AristoDbRef; vtxID: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  if db.vidGen.len == 0:
    db.vidGen = @[vtxID]
  else:
    let topID = db.vidGen[^1]
    # No need to store smaller numbers: all numberts larger than `topID`
    # are free numbers
    if vtxID < topID:
      db.vidGen[^1] = vtxID
      db.vidGen.add topID

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
