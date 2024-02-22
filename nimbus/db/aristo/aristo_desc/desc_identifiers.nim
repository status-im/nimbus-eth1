# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Identifier types
## =============================
##

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, strutils, hashes],
  eth/[common, trie/nibbles],
  stew/byteutils,
  chronicles,
  results,
  stint

type
  QueueID* = distinct uint64
    ## Identifier used to tag filter logs stored on the backend.

  FilterID* = distinct uint64
    ## Identifier used to identify a particular filter. It is generatied with
    ## the filter when stored to database.

  VertexID* = distinct uint64
    ## Unique identifier for a vertex of the `Aristo Trie`. The vertex is the
    ## prefix tree (aka `Patricia Trie`) component. When augmented by hash
    ## keys, the vertex component will be called a node. On the persistent
    ## backend of the database, there is no other reference to the node than
    ## the very same `VertexID`.

  HashKey* = object
    ## Ethereum MPTs use Keccak hashes as node links if the size of an RLP
    ## encoded node is of size at least 32 bytes. Otherwise, the RLP encoded
    ## node value is used as a pseudo node link (rather than a hash.) Such a
    ## node is nor stored on key-value database. Rather the RLP encoded node
    ## value is stored instead of a lode link in a parent node instead. Only
    ## for the root hash, the top level node is always referred to by the
    ## hash.
    ##
    ## This compaction feature needed an abstraction of the `HashKey` object
    ## which is either a `Hash256` or a `Blob` of length at most 31 bytes.
    ## This leaves two ways of representing an empty/void `HashKey` type.
    ## It may be available as an empty `Blob` of zero length, or the
    ## `Hash256` type of the Keccak hash of an empty `Blob` (see constant
    ## `EMPTY_ROOT_HASH`.)
    ##
    case isHash: bool
    of true:
      key: Hash256                   ## Merkle hash tacked to a vertex
    else:
      blob: Blob                     ## Optionally encoded small node data

  PathID* = object
    ## Path into the `Patricia Trie`. This is a chain of maximal 64 nibbles
    ## (which is 32 bytes.) In most cases, the length is 64. So the path is
    ## encoded as a numeric value which is often easier to handle than a
    ## chain of nibbles.
    ##
    ## The path ID should be kept normalised, i.e.
    ## * 0 <= `length` <= 64
    ## * the unused trailing nibbles in `pfx` are set to `0`
    ##
    pfx*: UInt256
    length*: uint8

  # ----------

  LeafTie* = object
    ## Unique access key for a leaf vertex. It identifies a root vertex
    ## followed by a nibble path along the `Patricia Trie` down to a leaf
    ## vertex. So this implies an obvious injection from the set of `LeafTie`
    ## objects *into* the set of `VertexID` obvious (which is typically *into*
    ## only, not a bijection.)
    ##
    ## Note that `LeafTie` objects have no representation in the `Aristo Trie`.
    ## They are used temporarily and in caches or backlog tables.
    root*: VertexID                  ## Root ID for the sub-trie
    path*: PathID                    ## Path into the `Patricia Trie`

# ------------------------------------------------------------------------------
# Chronicles formatters
# ------------------------------------------------------------------------------

chronicles.formatIt(VertexID): $it
chronicles.formatIt(QueueID): $it

# ------------------------------------------------------------------------------
# Public helpers: `VertexID` scalar data model
# ------------------------------------------------------------------------------

func `<`*(a, b: VertexID): bool {.borrow.}
func `<=`*(a, b: VertexID): bool {.borrow.}
func `==`*(a, b: VertexID): bool {.borrow.}
func cmp*(a, b: VertexID): int {.borrow.}

func `$`*(vid: VertexID): string =
  "$" & (if vid == VertexID(0): "ø"
         else: vid.uint64.toHex.strip(trailing=false,chars={'0'}).toLowerAscii)

func `==`*(a: VertexID; b: static[uint]): bool = (a == VertexID(b))

# Scalar model extension as in `IntervalSetRef[VertexID,uint64]`
func `+`*(a: VertexID; b: uint64): VertexID = (a.uint64+b).VertexID
func `-`*(a: VertexID; b: uint64): VertexID = (a.uint64-b).VertexID
func `-`*(a, b: VertexID): uint64 = (a.uint64 - b.uint64)

# ------------------------------------------------------------------------------
# Public helpers: `QueueID` scalar data model
# ------------------------------------------------------------------------------

func `<`*(a, b: QueueID): bool {.borrow.}
func `<=`*(a, b: QueueID): bool {.borrow.}
func `==`*(a, b: QueueID): bool {.borrow.}
func cmp*(a, b: QueueID): int {.borrow.}
func `$`*(a: QueueID): string {.borrow.}

func `==`*(a: QueueID; b: static[uint]): bool = (a == QueueID(b))

func `+`*(a: QueueID; b: uint64): QueueID = (a.uint64+b).QueueID
func `-`*(a: QueueID; b: uint64): QueueID = (a.uint64-b).QueueID
func `-`*(a, b: QueueID): uint64 = (a.uint64 - b.uint64)

# ------------------------------------------------------------------------------
# Public helpers: `FilterID` scalar data model
# ------------------------------------------------------------------------------

func `<`*(a, b: FilterID): bool {.borrow.}
func `<=`*(a, b: FilterID): bool {.borrow.}
func `==`*(a, b: FilterID): bool {.borrow.}
func `$`*(a: FilterID): string {.borrow.}

func `==`*(a: FilterID; b: static[uint]): bool = (a == FilterID(b))

func `+`*(a: FilterID; b: uint64): FilterID = (a.uint64+b).FilterID
func `-`*(a: FilterID; b: uint64): FilterID = (a.uint64-b).FilterID
func `-`*(a, b: FilterID): uint64 = (a.uint64 - b.uint64)

# ------------------------------------------------------------------------------
# Public helpers: `PathID` ordered scalar data model
# ------------------------------------------------------------------------------

func high*(_: type PathID): PathID =
  ## Highest possible `PathID` object for given root vertex.
  PathID(pfx: high(UInt256), length: 64)

func low*(_: type PathID): PathID =
  ## Lowest possible `PathID` object for given root vertex.
  PathID()

func next*(pid: PathID): PathID =
  ## Return a `PathID` object with incremented path field. This function might
  ## return also a modified `length` field.
  ##
  ## The function returns the argument `pid` if it is already at its
  ## maximum value `high(PathID)`.
  if pid.pfx.isZero and pid.length < 64:
    PathID(length: pid.length + 1)
  elif pid.pfx < high(UInt256):
    PathID(pfx: pid.pfx + 1, length: 64)
  else:
    pid

func prev*(pid: PathID): PathID =
  ## Return a `PathID` object with decremented path field. This function might
  ## return also a modified `length` field.
  ##
  ## The function returns the argument `pid` if it is already at its
  ## minimum value `low(PathID)`.
  if 0 < pid.pfx:
    PathID(pfx: pid.pfx - 1, length: 64)
  elif 0 < pid.length:
    PathID(length: pid.length - 1)
  else:
    pid

func `<`*(a, b: PathID): bool =
  ## This function assumes that the arguments `a` and `b` are normalised
  ## (see `normal()`.)
  a.pfx < b.pfx or (a.pfx == b.pfx and a.length < b.length)

func `<=`*(a, b: PathID): bool =
  not (b < a)

func `==`*(a, b: PathID): bool =
  ## This function assumes that the arguments `a` and `b` are normalised
  ## (see `normal()`.)
  a.pfx == b.pfx and a.length == b.length

func cmp*(a, b: PathID): int =
  if a < b: -1 elif b < a: 1 else: 0

func to*(lid: HashKey; T: type PathID): T =
  ## Helper to bowrrow certain properties from `PathID`
  if lid.isHash:
    PathID(pfx: UInt256.fromBytesBE lid.key.data, length: 64)
  elif 0 < lid.blob.len:
    doAssert lid.blob.len < 32
    var a32: array[32,byte]
    (addr a32[0]).copyMem(unsafeAddr lid.blob[0], lid.blob.len)
    PathID(pfx: UInt256.fromBytesBE a32, length: 2 * lid.blob.len.uint8)
  else:
    PathID()

# ------------------------------------------------------------------------------
# Public helpers: `HashKey` ordered scalar data model
# ------------------------------------------------------------------------------

func len*(lid: HashKey): int =
  if lid.isHash: 32 else: lid.blob.len

func fromBytes*(T: type HashKey; data: openArray[byte]): Result[T,void] =
  ## Write argument `data` of length 0 or between 2 and 32 bytes as a `HashKey`.
  ##
  ## A function argument `data` of length 32 is used as-is.
  ##
  ## For a function argument `data` of length between 2 and 31, the first
  ## byte must be the start of an RLP encoded list, i.e. `0xc0 + len` where
  ## where `len` is one less as the `data` length.
  ##
  if data.len == 32:
    var lid: T
    lid.isHash = true
    (addr lid.key.data[0]).copyMem(unsafeAddr data[0], data.len)
    return ok lid
  if data.len == 0:
    return ok HashKey()
  if 1 < data.len and data.len < 32 and data[0].int == 0xbf + data.len:
    return ok T(isHash: false, blob: @data)
  err()

func `<`*(a, b: HashKey): bool =
  ## Slow, but useful for debug sorting
  a.to(PathID) < b.to(PathID)

func `==`*(a, b: HashKey): bool =
  if a.isHash != b.isHash:
    false
  elif a.isHash:
    a.key == b.key
  else:
    a.blob == b.blob

func cmp*(a, b: HashKey): int =
  ## Slow, but useful for debug sorting
  if a < b: -1 elif b < a: 1 else: 0

# ------------------------------------------------------------------------------
# Public helpers: `LeafTie` ordered scalar data model
# ------------------------------------------------------------------------------

func high*(_: type LeafTie; root = VertexID(1)): LeafTie =
  ## Highest possible `LeafTie` object for given root vertex.
  LeafTie(root: root, path: high(PathID))

func low*(_: type LeafTie; root = VertexID(1)): LeafTie =
  ## Lowest possible `LeafTie` object for given root vertex.
  LeafTie(root: root, path: low(PathID))

func next*(lty: LeafTie): LeafTie =
  ## Return a `LeafTie` object with the `next()` path field.
  LeafTie(root: lty.root, path: lty.path.next)

func prev*(lty: LeafTie): LeafTie =
  ## Return a `LeafTie` object with the `prev()` path field.
  LeafTie(root: lty.root, path: lty.path.prev)

func `<`*(a, b: LeafTie): bool =
  ## This function assumes that the arguments `a` and `b` are normalised
  ## (see `normal()`.)
  a.root < b.root or (a.root == b.root and a.path < b.path)

func `==`*(a, b: LeafTie): bool =
  ## This function assumes that the arguments `a` and `b` are normalised
  ## (see `normal()`.)
  a.root == b.root and a.path == b.path

func cmp*(a, b: LeafTie): int =
  ## This function assumes that the arguments `a` and `b` are normalised
  ## (see `normal()`.)
  if a < b: -1 elif a == b: 0 else: 1

# ------------------------------------------------------------------------------
# Public helpers: Reversible conversions between `PathID`, `HashKey`, etc.
# ------------------------------------------------------------------------------

func to*(key: HashKey; T: type Blob): T =
  ## Rewrite `HashKey` argument as `Blob` type of length between 0 and 32. A
  ## blob of length 32 is taken as a representation of a `HashKey` type while
  ## samller blobs are expected to represent an RLP encoded small node.
  if key.isHash:
    @(key.key.data)
  else:
    key.blob

func `@`*(lid: HashKey): Blob =
  ## Variant of `to(Blob)`
  lid.to(Blob)

func to*(pid: PathID; T: type NibblesSeq): T =
  ## Representation of a `PathID` as `NibbleSeq` (preserving full information)
  let nibbles = pid.pfx.toBytesBE.toSeq.initNibbleRange()
  if pid.length < 64:
    nibbles.slice(0, pid.length.int)
  else:
    nibbles

func to*(lid: HashKey; T: type Hash256): T =
  ## Returns the `Hash236` key if available, otherwise the Keccak hash of
  ## the `Blob` version.
  if lid.isHash:
    lid.key
  elif 0 < lid.blob.len:
    lid.blob.keccakHash
  else:
    EMPTY_ROOT_HASH

func to*(key: Hash256; T: type HashKey): T =
  ## This is an efficient version of `HashKey.fromBytes(key.data).value`, not
  ## to be confused with `digestTo(HashKey)`.
  if key == EMPTY_ROOT_HASH:
    T()
  else:
    T(isHash: true, key: key)

func to*(n: SomeUnsignedInt|UInt256; T: type PathID): T =
  ## Representation of a scalar as `PathID` (preserving full information)
  T(pfx: n.u256, length: 64)

# ------------------------------------------------------------------------------
# Public helpers: Miscellaneous mappings
# ------------------------------------------------------------------------------

func digestTo*(data: openArray[byte]; T: type HashKey): T =
  ## For argument `data` with length smaller than 32, import them as-is into
  ## the result. Otherwise import the Keccak hash of the argument `data`.
  if data.len < 32:
    result.blob = @data
  else:
    result.isHash = true
    result.key = data.keccakHash

func normal*(a: PathID): PathID =
  ## Normalise path ID representation
  result = a
  if 64 < a.length:
    result.length = 64
  elif a.length < 64:
    result.pfx = a.pfx and not (1.u256 shl (4 * (64 - a.length))) - 1.u256

# ------------------------------------------------------------------------------
# Public helpers: `Tables` and `Rlp` support
# ------------------------------------------------------------------------------

func hash*(a: PathID): Hash =
  ## Table/KeyedQueue mixin
  var h: Hash = 0
  h = h !& a.pfx.toBytesBE.hash
  h = h !& a.length.hash
  !$h

func hash*(a: HashKey): Hash =
  ## Table/KeyedQueue mixin
  var h: Hash = 0
  if a.isHash:
    h = h !& a.key.hash
  else:
    h = h !& a.blob.hash
  !$h

# ------------------------------------------------------------------------------
# Miscellaneous helpers
# ------------------------------------------------------------------------------

func `$`*(vids: seq[VertexID]): string =
  "[" & vids.toSeq.mapIt(
    "$" & it.uint64.toHex.strip(trailing=false,chars={'0'})
    ).join(",") & "]"

func `$`*(vids: HashSet[VertexID]): string =
  "{" & vids.toSeq.sorted.mapIt(
    "$" & it.uint64.toHex.strip(trailing=false,chars={'0'})
    ).join(",") & "}"

func `$`*(key: Hash256): string =
  let w = UInt256.fromBytesBE key.data
  if w == high(UInt256):
    "2^256-1"
  elif w == 0.u256:
    "0"
  elif w == 2.u256.pow 255:
    "2^255" # 800...
  elif w == 2.u256.pow 254:
    "2^254" # 400..
  elif w == 2.u256.pow 253:
    "2^253" # 200...
  elif w == 2.u256.pow 251:
    "2^252" # 100...
  else:
    w.toHex

func `$`*(key: HashKey): string =
  if key.isHash:
    $key.key
  else:
    key.blob.toHex & "[#" & $key.blob.len & "]"

func `$`*(a: PathID): string =
  if a.pfx.isZero.not:
    var dgts = $a.pfx.toHex
    if a.length < 64:
      dgts = dgts[0 ..< a.length]
    result = dgts.strip(
      leading=true, trailing=false, chars={'0'})
  elif a.length != 0:
    result = "0"
  if a.length < 64:
    result &= "(" & $a.length & ")"

func `$`*(a: LeafTie): string =
  if a.root != 0:
    result = ($a.root.uint64.toHex).strip(
      leading=true, trailing=false, chars={'0'})
  else:
    result = "0"
  result &= ":" & $a.path

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
