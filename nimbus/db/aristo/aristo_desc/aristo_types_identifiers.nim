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

  VertexID* = distinct uint64
    ## Unique identifier for a vertex of the `Aristo Trie`. The vertex is the
    ## prefix tree (aka `Patricia Trie`) component. When augmented by hash
    ## keys, the vertex component will be called a node. On the persistent
    ## backend of the database, there is no other reference to the node than
    ## the very same `VertexID`.

  HashID* = distinct UInt256
    ## Variant of a `Hash256` object that can be used in a order relation
    ## (i.e. it can be sorted.) Among temporary conversions for sorting, the
    ## `HashID` type is consistently used for addressing leaf vertices (see
    ## below `LeafTie`.)

  HashKey* = distinct ByteArray32
    ## Dedicated `Hash256` object variant that is used for labelling the
    ## vertices of the `Patricia Trie` in order to make it a
    ## `Merkle Patricia Tree`.

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
    path*: HashID                    ## Path into the `Patricia Trie`

  HashLabel* = object
    ## Merkle hash key uniquely associated with a vertex ID. As hashes in a
    ## `Merkle Patricia Tree` are unique only on a particular sub-trie, the
    ## hash key is paired with the top vertex of the relevant sub-trie. This
    ## construction is similar to the one of a `LeafTie` object.
    ##
    ## Note that `LeafTie` objects have no representation in the `Aristo Trie`.
    ## They are used temporarily and in caches or backlog tables.
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
func `$`*(a: VertexID): string = $a.uint64

func `==`*(a: VertexID; b: static[uint]): bool =
  a == VertexID(b)

# Scalar model extension for `IntervalSetRef[VertexID,uint64]`
proc `+`*(a: VertexID; b: uint64): VertexID = (a.uint64+b).VertexID
proc `-`*(a: VertexID; b: uint64): VertexID = (a.uint64-b).VertexID
proc `-`*(a, b: VertexID): uint64 = (a.uint64 - b.uint64)

# ------------------------------------------------------------------------------
# Public helpers: `HashID` scalar data model
# ------------------------------------------------------------------------------

func u256*(lp: HashID): UInt256 = lp.UInt256
func low*(T: type HashID): T = low(UInt256).T
func high*(T: type HashID): T = high(UInt256).T

func `+`*(a: HashID; b: UInt256): HashID = (a.u256+b).HashID
func `-`*(a: HashID; b: UInt256): HashID = (a.u256-b).HashID
func `-`*(a, b: HashID): UInt256 = (a.u256 - b.u256)

func `==`*(a, b: HashID): bool = a.u256 == b.u256
func `<=`*(a, b: HashID): bool = a.u256 <= b.u256
func `<`*(a, b: HashID): bool = a.u256 < b.u256

func cmp*(x, y: HashID): int = cmp(x.UInt256, y.UInt256)

# ------------------------------------------------------------------------------
# Public helpers: Conversions between `HashID`, `HashKey`, `Hash256`
# ------------------------------------------------------------------------------

func to*(hid: HashID; T: type Hash256): T =
  result.data = hid.UInt256.toBytesBE

func to*(hid: HashID; T: type HashKey): T =
  hid.UInt256.toBytesBE.T

func to*(key: HashKey; T: type HashID): T =
  UInt256.fromBytesBE(key.ByteArray32).T

func to*(key: HashKey; T: type Hash256): T =
  T(data: ByteArray32(key))

func to*(hash: Hash256; T: type HashKey): T =
  hash.data.T

func to*(key: Hash256; T: type HashID): T =
  key.data.HashKey.to(T)

# ------------------------------------------------------------------------------
# Public helpers: Miscellaneous mappings
# ------------------------------------------------------------------------------

func to*(key: HashKey; T: type Blob): T =
  ## Representation of a `HashKey` as `Blob` (preserving full information)
  key.ByteArray32.toSeq

func to*(key: HashKey; T: type NibblesSeq): T =
  ## Representation of a `HashKey` as `NibbleSeq` (preserving full information)
  key.ByteArray32.initNibbleRange()

func to*(hid: HashID; T: type NibblesSeq): T =
  ## Representation of a `HashKey` as `NibbleSeq` (preserving full information)
  ByteArray32(hid.to(HashKey)).initNibbleRange()

func to*(n: SomeUnsignedInt|UInt256; T: type HashID): T =
  ## Representation of a scalar as `HashID` (preserving full information)
  n.u256.T

func digestTo*(data: Blob; T: type HashKey): T =
  ## Keccak hash of a `Blob`, represented as a `HashKey`
  keccakHash(data).data.T

# ------------------------------------------------------------------------------
# Public helpers: `Tables` and `Rlp` support
# ------------------------------------------------------------------------------

func hash*(a: HashID): Hash =
  ## Table/KeyedQueue mixin
  a.to(HashKey).ByteArray32.hash

func hash*(a: HashKey): Hash =
  ## Table/KeyedQueue mixin
  a.ByteArray32.hash

func `==`*(a, b: HashKey): bool =
  ## Table/KeyedQueue mixin
  a.ByteArray32 == b.ByteArray32

func read*[T: HashID|HashKey](rlp: var Rlp, W: type T): T
    {.gcsafe, raises: [RlpError].} =
  rlp.read(Hash256).to(T)

func append*(writer: var RlpWriter, val: HashID|HashKey) =
  writer.append(val.to(Hash256))

# ------------------------------------------------------------------------------
# Public helpers: `LeafTie` scalar data model
# ------------------------------------------------------------------------------

func `<`*(a, b: LeafTie): bool =
  a.root < b.root or (a.root == b.root and a.path < b.path)

func `==`*(a, b: LeafTie): bool =
  a.root == b.root and a.path == b.path

func cmp*(a, b: LeafTie): int =
  if a < b: -1 elif a == b: 0 else: 1

func `$`*(a: LeafTie): string =
  let w = $a.root.uint64.toHex & ":" & $a.path.Uint256.toHex
  w.strip(leading=true, trailing=false, chars={'0'}).toLowerAscii

# ------------------------------------------------------------------------------
# Miscellaneous helpers
# ------------------------------------------------------------------------------

func `$`*(hid: HashID): string =
  if hid == high(HashID):
    "2^256-1"
  elif hid == 0.u256.HashID:
    "0"
  elif hid == 2.u256.pow(255).HashID:
    "2^255" # 800...
  elif hid == 2.u256.pow(254).HashID:
    "2^254" # 400..
  elif hid == 2.u256.pow(253).HashID:
    "2^253" # 200...
  elif hid == 2.u256.pow(251).HashID:
    "2^252" # 100...
  else:
    hid.UInt256.toHex

func `$`*(key: HashKey): string =
  $key.to(HashID)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
