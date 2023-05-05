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
  eth/[common, trie/nibbles],
  ../../sync/snap/range_desc,
  ./aristo_error

type
  VertexID* = distinct uint64      ## Tip of edge towards child, also table key

  NodeType* = enum                 ## Type of Patricia Trie node
    Dummy
    Leaf
    Extension
    Branch

  PayloadType* = enum              ## Type of leaf data (to be extended)
    BlobData
    AccountData

  PayloadRef* = ref object
    case kind*: PayloadType
    of BlobData:
      blob*: Blob                  ## Opaque data value reference
    of AccountData:
      account*: Account            ## Expanded accounting data

  NodeRef* = ref object
    ## Vertex for building a hexary Patricia or Merkle Patricia Trie
    case kind*: NodeType
    of Dummy:
      reason*: AristoError         ## Empty record, can be used error signalling
    of Leaf:
      lPfx*: NibblesSeq            ## Portion of path segment
      lData*: PayloadRef           ## Reference to data payload
    of Extension:
      ePfx*: NibblesSeq            ## Portion of path segment
      eVtx*: VertexID              ## Edge to vertex with ID `eVtx`
      eKey*: NodeKey               ## Hash value (if any) or temporary key
    of Branch:
      bVtx*: array[16,VertexID]    ## Edge list with vertex IDs
      bKey*: array[16,NodeKey]     ## Merkle hashes
      #
      # Paraphrased comment from Andri's `stateless/readme.md` file in chapter
      # `Deviation from yellow paper`, (also found here
      #      github.com/status-im/nimbus-eth1
      #         /tree/master/stateless#deviation-from-yellow-paper)
      # [..] In the Yellow Paper, the 17th elem of the branch node can contain
      # a value. But it is always empty in a real Ethereum state trie. The
      # block witness spec also ignores this 17th elem when encoding or
      # decoding a branch node. This can happen because in a Ethereum secure
      # hexary trie, every keys have uniform length of 32 bytes or 64 nibbles.
      # With the absence of the 17th element, a branch node will never contain
      # a leaf value.
      #
      # => data value omitted as it will not be used

  PathStep* = object
    ## For constructing a tree traversal path
    key*: NodeKey                  ## Node label
    node*: NodeRef                 ## Referes to data record
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
    pathTag*: NodeTag              ## Patricia Trie key path
    nodeVtx*: VertexID             ## Table lookup vertex ID (if any)
    payload*: PayloadRef           ## Reference to data payload

  GetFn* = proc(key: openArray[byte]): Blob
    {.gcsafe, raises: [CatchableError].}
      ## Persistent database `get()` function. For read-only cases, this
      ## function can be seen as the persistent alternative to ``tab[]` on
      ## a `HexaryTreeDbRef` descriptor.

  AristoDbRef* = ref object
    ## Hexary trie plus helper structures
    tab*: Table[VertexID,NodeRef]  ## Vertex table making up trie
    refGen*: seq[VertexID]         ## Unique key generator

    # Debugging data below, might go away in future
    xMap*: Table[NodeKey,VertexID] ## Mapper for pretty printing

static:
  # Not that there is no doubt about this ...
  doAssert NodeKey.default.ByteArray32.initNibbleRange.len == 64

# ------------------------------------------------------------------------------
# Public constructor (or similar)
# ------------------------------------------------------------------------------

proc new*(T: type VertexID; db: AristoDbRef): T =
  ## Create a new `VertexID`. Reusable *ID*s are kept in a list where the top
  ## entry *ID0* has the property that any other *ID* larger *ID0* is also not
  ## not used on the databse.
  if db.refGen.len == 0:
    db.refGen = @[2u64.VertexID]
    return 1u64.VertexID
  result = db.refGen[^1]
  if db.refGen.len == 1:
    db.refGen = @[(result.uint64 + 1).VertexID]
  else:
    db.refGen.setLen(db.refGen.len-1)

proc peek*(T: type VertexID; db: AristoDbRef): T =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  if db.refGen.len == 0: 1u64 else: db.refGen[^1]

proc dispose*(db: AristoDbRef; vtxID: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  if db.refGen.len == 0:
    db.refGen = @[vtxID]
  else:
    let topID = db.refGen[^1]
    db.refGen[^1] = vtxID
    db.refGen.add topID

# ------------------------------------------------------------------------------
# Public helpers: `VertexID` scalar data model
# ------------------------------------------------------------------------------

proc `==`*(a, b: VertexID): bool {.borrow.}
proc cmp*(a, b: VertexID): int {.borrow.}
proc `$`*(a: VertexID): string = $a.uint64

# ------------------------------------------------------------------------------
# Public helpers: `NodeRef` and `PayloadRef`
# ------------------------------------------------------------------------------

proc `==`*(a, b: PayloadRef): bool =
  ## Beware, potentially deep comparison
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a) != unsafeAddr(b):
    if a.kind != b.kind:
      return false
    case a.kind:
    of BlobData:
      if a.blob != b.blob:
        return false
    of AccountData:
      if a.account != b.account:
        return false
  true

proc `==`*(a, b: NodeRef): bool =
  ## Beware, potentially deep comparison
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a) != unsafeAddr(b):
    if a.kind != b.kind:
      return false
    case a.kind:
    of Dummy:
      if a.reason != b.reason:
        return false
    of Leaf:
      if a.lPfx != b.lPfx or a.lData != b.lData:
        return false
    of Extension:
      if a.ePfx != b.ePfx or a.eVtx != b.eVtx or a.eKey != b.eKey:
        return false
    of Branch:
      for n in 0 .. 15:
        if a.bVtx[n] != b.bVtx[n] or a.bKey[n] != b.bKey[n]:
          return false
  true

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous functions
# ------------------------------------------------------------------------------

proc isZero*[T: NodeKey|VertexID](a: T): bool =
  a == typeof(a).default

proc convertTo*(payload: PayloadRef; T: type Blob): T =
  ## Probably lossy conversion as the storage type `kind` gets missing
  case payload.kind:
  of BlobData:
    result = payload.blob
  of AccountData:
    result = rlp.encode payload.account

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
