# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  std/[sequtils, strutils, hashes],
  eth/[common, trie/nibbles],
  stint

type
  ByteArray32* = array[32,byte]
    ## Used for 32 byte hash components repurposed as Merkle hash labels.

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

  HashKey* = distinct ByteArray32
    ## Dedicated `Hash256` object variant that is used for labelling the
    ## vertices of the `Patricia Trie` in order to make it a
    ## `Merkle Patricia Tree`.

  PathID* = object
    ## Path into the `Patricia Trie`. This is a chain of maximal 64 nibbles
    ## (which is 32 bytes.) In most cases, the length is 64. So the path is
    ## encoded as a numeric value which is often easier to handle than a
    ## chain of nibbles.
    ##
    ## The path ID should be kept normalised, i.e.
    ## * 0 <= `length` <= 64
    ## * the unused trailing nibbles in `pfx` ar set to `0`
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

  HashLabel* = object
    ## Merkle hash key uniquely associated with a vertex ID. As hashes in a
    ## `Merkle Patricia Tree` are unique only on a particular sub-trie, the
    ## hash key is paired with the top vertex of the relevant sub-trie. This
    ## construction is similar to the one of a `LeafTie` object.
    ##
    ## Note that `HashLabel` objects have no representation in the
    ## `Aristo Trie`. They are used temporarily and in caches or backlog
    ## tables.
    root*: VertexID                  ## Root ID for the sub-trie.
    key*: HashKey                    ## Merkle hash tacked to a vertex.

static:
  # Not that there is no doubt about this ...
  doAssert HashKey.default.ByteArray32.initNibbleRange.len == 64

# ------------------------------------------------------------------------------
# Public helpers: `VertexID` scalar data model
# ------------------------------------------------------------------------------

func `<`*(a, b: VertexID): bool {.borrow.}
func `<=`*(a, b: VertexID): bool {.borrow.}
func `==`*(a, b: VertexID): bool {.borrow.}
func cmp*(a, b: VertexID): int {.borrow.}
func `$`*(a: VertexID): string {.borrow.}

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
  if pid.pfx == 0 and pid.length < 64:
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

proc to*(key: HashKey; T: type UInt256): T =
  T.fromBytesBE key.ByteArray32

func to*(key: HashKey; T: type Hash256): T =
  T(data: ByteArray32(key))

func to*(key: HashKey; T: type PathID): T =
  ## Not necessarily reversible for shorter lengths `PathID` values
  T(pfx: UInt256.fromBytesBE key.ByteArray32, length: 64)

func to*(hash: Hash256; T: type HashKey): T =
  hash.data.T

func to*(key: HashKey; T: type Blob): T =
  ## Representation of a `HashKey` as `Blob` (preserving full information)
  key.ByteArray32.toSeq

func to*(key: HashKey; T: type NibblesSeq): T =
  ## Representation of a `HashKey` as `NibbleSeq` (preserving full information)
  key.ByteArray32.initNibbleRange()

func to*(pid: PathID; T: type NibblesSeq): T =
  ## Representation of a `HashKey` as `NibbleSeq` (preserving full information)
  let nibbles = pid.pfx.UInt256.toBytesBE.toSeq.initNibbleRange()
  if pid.length < 64:
    nibbles.slice(0, pid.length.int)
  else:
    nibbles

func to*(n: SomeUnsignedInt|UInt256; T: type PathID): T =
  ## Representation of a scalar as `PathID` (preserving full information)
  T(pfx: n.u256, length: 64)

# ------------------------------------------------------------------------------
# Public helpers: Miscellaneous mappings
# ------------------------------------------------------------------------------

func digestTo*(data: openArray[byte]; T: type HashKey): T =
  ## Keccak hash of a `Blob` like argument, represented as a `HashKey`
  keccakHash(data).data.T

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

func hash*(a: HashKey): Hash {.borrow.}

func `==`*(a, b: HashKey): bool {.borrow.}

func read*(rlp: var Rlp; T: type HashKey;): T {.gcsafe, raises: [RlpError].} =
  rlp.read(Hash256).to(T)

func append*(writer: var RlpWriter, val: HashKey) =
  writer.append(val.to(Hash256))

# ------------------------------------------------------------------------------
# Miscellaneous helpers
# ------------------------------------------------------------------------------

func `$`*(key: HashKey): string =
  let w = UInt256.fromBytesBE key.ByteArray32
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

func `$`*(a: PathID): string =
  if a.pfx != 0:
    result = ($a.pfx.toHex).strip(
      leading=true, trailing=false, chars={'0'}).toLowerAscii
  elif a.length != 0:
    result = "0"
  if a.length < 64:
    result &= "(" & $a.length & ")"

func `$`*(a: LeafTie): string =
  if a.root != 0:
    result = ($a.root.uint64.toHex).strip(
      leading=true, trailing=false, chars={'0'}).toLowerAscii
  else:
    result = "0"
  result &= ":" & $a.path

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
