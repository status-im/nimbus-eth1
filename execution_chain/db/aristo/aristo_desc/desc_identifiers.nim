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
  eth/common/[base, hashes],
  eth/rlp,
  stew/byteutils,
  chronicles,
  results,
  stint,
  ./desc_nibbles

export
  desc_nibbles, base, hashes, rlp

type
  VertexID* = distinct uint64
    ## Unique identifier for a vertex of the `Aristo Trie`. The vertex is the
    ## prefix tree (aka `Patricia Trie`) component. When augmented by hash
    ## keys, the vertex component will be called a node. On the persistent
    ## backend of the database, there is no other reference to the node than
    ## the very same `VertexID`.
    ##
    ## Vertex IDs are generated on the fly and thrown away when not needed,
    ## anymore. They are not recycled. A quick estimate
    ##
    ##   (2^64) / (100 * 365.25 * 24 * 3600) / 1000 / 1000 / 1000 = 5.86
    ##
    ## shows that the `uint64` scalar space is not exhausted in a 100 years
    ## if the database consumes somewhat less than 6 IDs per nanosecond.
    ##
    ## A simple recycling mechanism was tested which slowed down the system
    ## considerably because large swaths of database vertices were regularly
    ## freed so recycling had do deal with extensive lists of non-consecutive
    ## IDs.

  RootedVertexID* = tuple[root, vid: VertexID]
    ## Vertex and the root it belongs to in the MPT. Used to group a set of
    ## verticies, for example to store them together in the database or perform
    ## range operations.
    ##
    ## `vid` may be a branch, extension or leaf.
    ##
    ## To reference the root itself, use (root, root).

  HashKey* = object
    ## Ethereum reference MPTs use Keccak hashes as node links if the size of
    ## an RLP encoded node is at least 32 bytes. Otherwise, the RLP encoded
    ## node value is used as a pseudo node link (rather than a hash.) This is
    ## specified in the yellow paper, appendix D. Only for the root hash, the
    ## top level node is always referred to by the Keccak hash.
    ##
    ## On the `Aristo` database node links are called keys which are of this
    ## very type `HashKey`. For key-value tables (which assign a key to a
    ## vertex), the keys are always stored as such with length probably
    ## smaller than 32, including for root vertex keys. Only when used as a
    ## root state, the key of the latter is digested to a Keccak hash
    ## on-the-fly.
    ##
    ## This compaction feature nees an abstraction of the hash link object
    ## which is either a `Hash32` or a `seq[byte]` of length at most 31 bytes.
    ## This leaves two ways of representing an empty/void `HashKey` type.
    ## It may be available as an empty `seq[byte]` of zero length, or the
    ## `Hash32` type of the Keccak hash of an empty `seq[byte]` (see constant
    ## `EMPTY_ROOT_HASH`.)
    ##
    ## For performance, storing blobs as `seq` is avoided, instead storing
    ## their length and sharing the data "space".
    ##
    buf: array[32, byte] # Either Hash32 or blob data, depending on `len`
    len: int8 # length in the case of blobs, or 32 when it's a hash

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

func `==`*(a, b: RootedVertexID): bool {.inline.} =
  a.vid == b.vid

func hash*(rvid: RootedVertexID): Hash {.inline.} =
  hash(rvid.vid)

func `$`*(rvid: RootedVertexID): string =
  $rvid.root & "/" & $rvid.vid

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

# ------------------------------------------------------------------------------
# Public helpers: `HashKey` ordered scalar data model
# ------------------------------------------------------------------------------

func len*(lid: HashKey): int =
  lid.len.int # if lid.isHash: 32 else: lid.blob.len

template data*(lid: HashKey): openArray[byte] =
  lid.buf.toOpenArray(0, lid.len - 1)

func to*(lid: HashKey; T: type PathID): T =
  ## Helper to bowrrow certain properties from `PathID`
  if lid.len == 32:
    PathID(pfx: UInt256.fromBytesBE lid.data, length: 64)
  elif 0 < lid.len:
    doAssert lid.len < 32
    var a32: array[32,byte]
    (addr a32[0]).copyMem(unsafeAddr lid.data[0], lid.len)
    PathID(pfx: UInt256.fromBytesBE a32, length: 2 * lid.len.uint8)
  else:
    PathID()

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
    lid.len = 32
    (addr lid.data[0]).copyMem(unsafeAddr data[0], data.len)
    return ok lid
  if data.len == 0:
    return ok HashKey()
  if 1 < data.len and data.len < 32 and data[0].int == 0xbf + data.len:
    var lid: T
    lid.len = int8 data.len
    (addr lid.data[0]).copyMem(unsafeAddr data[0], data.len)
    return ok lid
  err()

func `<`*(a, b: HashKey): bool =
  ## Slow, but useful for debug sorting
  a.to(PathID) < b.to(PathID)

func `==`*(a, b: HashKey): bool =
  a.data == b.data

func cmp*(a, b: HashKey): int =
  ## Slow, but useful for debug sorting
  cmp(a.data, b.data)

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

func to*(pid: PathID; T: type NibblesBuf): T =
  ## Representation of a `PathID` as `NibbleSeq` (preserving full information)
  let nibbles = NibblesBuf.fromBytes(pid.pfx.toBytesBE)
  if pid.length < 64:
    nibbles.slice(0, pid.length.int)
  else:
    nibbles

func `@`*(pid: PathID): seq[byte] =
  ## Representation of a `PathID` as a `seq[byte]`. The result is left padded
  ## by a zero LSB if the path length was odd.
  result = pid.pfx.toBytesBE.toSeq
  if pid.length < 63:
    result.setLen((pid.length + 1) shl 1)

func to*(lid: HashKey; T: type Hash32): T =
  ## Returns the `Hash236` key if available, otherwise the Keccak hash of
  ## the `seq[byte]` version.
  if lid.len == 32:
    Hash32(lid.buf)
  elif 0 < lid.len:
    lid.data.keccak256
  else:
    emptyRoot

func to*(key: Hash32; T: type HashKey): T =
  ## This is an efficient version of `HashKey.fromBytes(key.data).value`, not
  ## to be confused with `digestTo(HashKey)`.
  if key == emptyRoot:
    T()
  else:
    T(len: 32, buf: key.data)

func to*(n: SomeUnsignedInt; T: type PathID): T =
  ## Representation of a scalar as `PathID` (preserving full information)
  T(pfx: n.u256, length: 64)

func to*(n: UInt256; T: type PathID): T =
  ## Representation of a scalar as `PathID` (preserving full information)
  T(pfx: n, length: 64)

func to*(a: PathID; T: type UInt256): T =
  if not a.pfx.isZero:
    assert a.length < 64 # debugging only
    result = a.pfx shr (4 * (64 -  a.length))

# ------------------------------------------------------------------------------
# Public helpers: Miscellaneous mappings
# ------------------------------------------------------------------------------

func digestTo*(data: openArray[byte]; T: type HashKey): T =
  ## For argument `data` with length smaller than 32, import them as-is into
  ## the result. Otherwise import the Keccak hash of the argument `data`.
  ##
  ## The `data` argument is only hashed if the `data` length is at least
  ## 32 bytes. Otherwise it is converted as-is to a `HashKey` type result.
  ##
  ## Note that for calculating a root state (when `data` is a serialised
  ## vertex), one would use the expression `data.digestTo(HashKey).to(Hash32)`
  ## which would always hash the `data` argument regardless of its length
  ## (and might result in an `EMPTY_ROOT_HASH`.) See the comment at the
  ## definition of the `HashKey` type for an explanation of its usage.
  ##
  if data.len == 0:
    result.len = 0
  elif data.len < 32:
    result.len = int8 data.len
    (addr result.data[0]).copyMem(unsafeAddr data[0], data.len)
  else:
    result.len = 32
    result.buf = data.keccak256.data

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
  hash(a.data)

func append*(w: var RlpWriter; key: HashKey) =
  if 1 < key.len and key.len < 32:
    w.appendRawBytes key.data
  else:
    w.append key.data

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

func `$`*(key: HashKey): string =
  toHex(key.data)

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
