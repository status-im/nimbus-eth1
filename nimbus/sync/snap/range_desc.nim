# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[math, sequtils, strutils, hashes],
  eth/common,
  stew/[byteutils, interval_set],
  stint,
  ../../constants,
  ../protocol,
  ../types

{.push raises: [].}

type
  ByteArray32* = array[32,byte]
    ## Used for 32 byte database keys

  NodeKey* = distinct ByteArray32
    ## Hash key without the hash wrapper (as opposed to `NodeTag` which is a
    ## number.)

  NodeTag* = distinct UInt256
    ## Trie leaf item, account hash etc. This data type is a representation
    ## for a `NodeKey` geared up for arithmetic and comparing keys.

  NodeTagRange* = Interval[NodeTag,UInt256]
    ## Interval `[minPt,maxPt]` of` NodeTag` elements, can be managed in an
    ## `IntervalSet` data type.

  NodeTagRangeSet* = IntervalSetRef[NodeTag,UInt256]
    ## Managed structure to handle non-adjacent `NodeTagRange` intervals

  NodeSpecs* = object
    ## Multi purpose descriptor for a hexary trie node:
    ## * Missing node specs. If the `data` argument is empty, the `partialPath`
    ##   refers to a missoing node entry. The `nodeKey` is another way of
    ##   writing the node hash and used to verify that a potential data `Blob`
    ##   is acceptable as node data.
    ## * Node data. If the `data` argument is non-empty, the `partialPath`
    ##   fields can/will be used as function argument for various functions
    ##   when healing.
    partialPath*: Blob             ## Compact encoded partial path nibbles
    nodeKey*: NodeKey              ## Derived from node hash
    data*: Blob                    ## Node data (might not be present)

  PackedAccountRange* = object
    ## Re-packed version of `SnapAccountRange`. The reason why repacking is
    ## needed is that the `snap/1` protocol uses another RLP encoding than is
    ## used for storing in the database. So the `PackedAccount` is `BaseDB`
    ## trie compatible.
    accounts*: seq[PackedAccount]  ## List of re-packed accounts data
    proof*: SnapAccountProof       ## Boundary proofs

  PackedAccount* = object
    ## In fact, the `snap/1` driver returns the `Account` structure which is
    ## unwanted overhead, here.
    accKey*: NodeKey
    accBlob*: Blob

  AccountSlotsHeader* = object
    ## Storage root header
    accKey*: NodeKey                ## Owner account, maybe unnecessary
    storageRoot*: Hash256           ## Start of storage tree
    subRange*: Option[NodeTagRange] ## Sub-range of slot range covered

  AccountStorageRange* = object
    ## List of storage descriptors, the last `AccountSlots` storage data might
    ## be incomplete and the `proof` is needed for proving validity.
    storages*: seq[AccountSlots]    ## List of accounts and storage data
    proof*: SnapStorageProof        ## Boundary proofs for last entry
    base*: NodeTag                  ## Lower limit for last entry w/proof

  AccountSlots* = object
    ## Account storage descriptor
    account*: AccountSlotsHeader
    data*: seq[SnapStorage]

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc to*(tag: NodeTag; T: type Hash256): T =
  ## Convert to serialised equivalent
  result.data = tag.UInt256.toBytesBE

proc to*(key: NodeKey; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(key.ByteArray32).T

proc to*(key: Hash256; T: type NodeTag): T =
  ## Syntactic sugar
  key.data.NodeKey.to(T)

proc to*(tag: NodeTag; T: type NodeKey): T =
  ## Syntactic sugar
  tag.UInt256.toBytesBE.T

proc to*(hash: Hash256; T: type NodeKey): T =
  ## Syntactic sugar
  hash.data.NodeKey

proc to*(key: NodeKey; T: type Hash256): T =
  ## Syntactic sugar
  T(data: key.ByteArray32)

proc to*(key: NodeKey; T: type Blob): T =
  ## Syntactic sugar
  key.ByteArray32.toSeq

proc to*(n: SomeUnsignedInt|UInt256; T: type NodeTag): T =
  ## Syntactic sugar
  n.u256.T

proc digestTo*(data: Blob; T: type NodeKey): T =
  keccakHash(data).data.T


proc hash*(a: NodeKey): Hash =
  ## Table/KeyedQueue mixin
  a.ByteArray32.hash

proc `==`*(a, b: NodeKey): bool =
  ## Table/KeyedQueue mixin
  a.ByteArray32 == b.ByteArray32

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc init*(key: var NodeKey; data: openArray[byte]): bool =
  ## Import argument `data` into `key` which must have length either `32`, or
  ## `0`. The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    (addr key.ByteArray32[0]).copyMem(unsafeAddr data[0], data.len)
    return true
  elif data.len == 0:
    key.reset
    return true

proc init*(tag: var NodeTag; data: openArray[byte]): bool =
  ## Similar to `init(key: var NodeHash; .)`.
  var key: NodeKey
  if key.init(data):
    tag = key.to(NodeTag)
    return true

# ------------------------------------------------------------------------------
# Public rlp support
# ------------------------------------------------------------------------------

proc read*[T: NodeTag|NodeKey](rlp: var Rlp, W: type T): T
    {.gcsafe, raises: [RlpError].} =
  rlp.read(Hash256).to(T)

proc append*(writer: var RlpWriter, val: NodeTag|NodeKey) =
  writer.append(val.to(Hash256))

# ------------------------------------------------------------------------------
# Public `NodeTag` and `NodeTagRange` functions
# ------------------------------------------------------------------------------

proc u256*(lp: NodeTag): UInt256 = lp.UInt256
proc low*(T: type NodeTag): T = low(UInt256).T
proc high*(T: type NodeTag): T = high(UInt256).T

proc `+`*(a: NodeTag; b: UInt256): NodeTag = (a.u256+b).NodeTag
proc `-`*(a: NodeTag; b: UInt256): NodeTag = (a.u256-b).NodeTag
proc `-`*(a, b: NodeTag): UInt256 = (a.u256 - b.u256)

proc `==`*(a, b: NodeTag): bool = a.u256 == b.u256
proc `<=`*(a, b: NodeTag): bool = a.u256 <= b.u256
proc `<`*(a, b: NodeTag): bool = a.u256 < b.u256

proc cmp*(x, y: NodeTag): int = cmp(x.UInt256, y.UInt256)

proc hash*(a: NodeTag): Hash =
  ## Mixin for `Table` or `keyedQueue`
  a.to(Hash256).data.hash

proc digestTo*(data: Blob; T: type NodeTag): T =
  ## Hash the `data` argument
  keccakHash(data).to(T)

# ------------------------------------------------------------------------------
# Public functions: `NodeTagRange` helpers
# ------------------------------------------------------------------------------

proc isEmpty*(lrs: NodeTagRangeSet): bool =
  ## Returns `true` if the argument set `lrs` of intervals is empty
  lrs.chunks == 0

proc isEmpty*(lrs: openArray[NodeTagRangeSet]): bool =
  ## Variant of `isEmpty()` where intervals are distributed across several
  ## sets.
  for ivSet in lrs:
    if 0 < ivSet.chunks:
      return false
  true

proc isFull*(lrs: NodeTagRangeSet): bool =
  ## Returns `true` if the argument set `lrs` contains of the single
  ## interval [low(NodeTag),high(NodeTag)].
  lrs.total == 0 and 0 < lrs.chunks


proc emptyFactor*(lrs: NodeTagRangeSet): float =
  ## Relative uncovered total, i.e. `#points-not-covered / 2^256` to be used
  ## in statistics or triggers.
  if 0 < lrs.total:
    ((high(NodeTag) - lrs.total).u256 + 1).to(float) / (2.0^256)
  elif lrs.chunks == 0:
    1.0 # `total` represents the residue class `mod 2^256` from `0`..`(2^256-1)`
  else:
    0.0 # number of points in `lrs` is `2^256 + 1`

proc emptyFactor*(lrs: openArray[NodeTagRangeSet]): float =
  ## Variant of `emptyFactor()` where intervals are distributed across several
  ## sets. This function makes sense only if the interval sets are mutually
  ## disjunct.
  var accu: NodeTag
  for ivSet in lrs:
    if 0 < ivSet.total:
      if high(NodeTag) - ivSet.total < accu:
        return 0.0
      accu = accu + ivSet.total
    elif ivSet.chunks == 0:
      discard
    else: # number of points in `ivSet` is `2^256 + 1`
      return 0.0
  if accu == 0.to(NodeTag):
    return 1.0
  ((high(NodeTag) - accu).u256 + 1).to(float) / (2.0^256)


proc fullFactor*(lrs: NodeTagRangeSet): float =
  ## Relative covered total, i.e. `#points-covered / 2^256` to be used
  ## in statistics or triggers
  if 0 < lrs.total:
    lrs.total.u256.to(float) / (2.0^256)
  elif lrs.chunks == 0:
    0.0 # `total` represents the residue class `mod 2^256` from `0`..`(2^256-1)`
  else:
    1.0 # number of points in `lrs` is `2^256 + 1`

proc fullFactor*(iv: NodeTagRange): float =
  ## Relative covered length of an inetrval, i.e. `#points-covered / 2^256`
  if 0 < iv.len:
    iv.len.u256.to(float) / (2.0^256)
  else:
    1.0 # number of points in `iv` is `2^256 + 1`

# ------------------------------------------------------------------------------
# Public functions: printing & pretty printing
# ------------------------------------------------------------------------------

proc `$`*(nodeTag: NodeTag): string =
  if nodeTag == high(NodeTag):
    "2^256-1"
  elif nodeTag == 0.u256.NodeTag:
    "0"
  else:
    nodeTag.to(Hash256).data.toHex

proc `$`*(nodeKey: NodeKey): string =
  $nodeKey.to(NodeTag)

proc leafRangePp*(a, b: NodeTag): string =
  ## Needed for macro generated DSL files like `snap.nim` because the
  ## `distinct` flavour of `NodeTag` is discarded there.
  result = "[" & $a
  if a != b:
    result &= ',' & $b
  result &= "]"

proc leafRangePp*(iv: NodeTagRange): string =
  ## Variant of `leafRangePp()`
  leafRangePp(iv.minPt, iv.maxPt)


proc `$`*(a, b: NodeTag): string =
  ## Prettyfied prototype
  leafRangePp(a,b)

proc `$`*(iv: NodeTagRange): string =
  leafRangePp iv


proc dump*(
    ranges: openArray[NodeTagRangeSet];
    moan: proc(overlap: UInt256; iv: NodeTagRange) {.gcsafe.};
    printRangesMax = high(int);
      ): string =
  ## Dump/anlalyse range sets
  var
    cache: NodeTagRangeSet
    ivTotal = 0.u256
    ivCarry = false

  if ranges.len == 1:
    cache = ranges[0]
    ivTotal = cache.total
    if ivTotal == 0.u256 and 0 < cache.chunks:
      ivCarry = true
  else:
    cache = NodeTagRangeSet.init()
    for ivSet in ranges:
      if ivSet.total == 0.u256 and 0 < ivSet.chunks:
        ivCarry = true
      elif ivTotal <= high(UInt256) - ivSet.total:
        ivTotal += ivSet.total
      else:
        ivCarry = true
      for iv in ivSet.increasing():
        let n = cache.merge(iv)
        if n != iv.len and not moan.isNil:
          moan(iv.len - n, iv)

  if 0 == cache.total and 0 < cache.chunks:
    result = "2^256"
    if not ivCarry:
      result &= ":" & $ivTotal
  else:
    result = $cache.total
    if ivCarry:
      result &= ":2^256"
    elif ivTotal != cache.total:
      result &= ":" & $ivTotal

  result &= ":"
  if cache.chunks <= printRangesMax:
    result &= toSeq(cache.increasing).mapIt($it).join(",")
  else:
    result &= toSeq(cache.increasing).mapIt($it)[0 ..< printRangesMax].join(",")
    result &= " " & $(cache.chunks - printRangesMax) & " more .."

proc dump*(
    range: NodeTagRangeSet;
    printRangesMax = high(int);
      ): string =
  ## Ditto
  [range].dump(nil, printRangesMax)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
