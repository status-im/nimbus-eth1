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
  std/[math, sequtils, hashes],
  eth/common/eth_types_rlp,
  stew/[byteutils, interval_set],
  stint,
  ../../constants,
  ../protocol,
  ../types

{.push raises: [Defect].}

type
  ByteArray32* = array[32,byte]
    ## Used for 32 byte database keys

  NodeKey* = distinct ByteArray32
    ## Hash key without the hash wrapper (as opposed to `NodeTag` which is a
    ## number)

  NodeTag* = distinct UInt256
    ## Trie leaf item, account hash etc.

  NodeTagRange* = Interval[NodeTag,UInt256]
    ## Interval `[minPt,maxPt]` of` NodeTag` elements, can be managed in an
    ## `IntervalSet` data type.

  NodeTagRangeSet* = IntervalSetRef[NodeTag,UInt256]
    ## Managed structure to handle non-adjacent `NodeTagRange` intervals

  PackedAccountRange* = object
    ## Re-packed version of `SnapAccountRange`. The reason why repacking is
    ## needed is that the `snap/1` protocol uses another RLP encoding than is
    ## used for storing in the database. So the `PackedAccount` is `BaseDB`
    ## trie compatible.
    accounts*: seq[PackedAccount]  ## List of re-packed accounts data
    proof*: SnapAccountProof       ## Boundary proofs

  PackedAccount* = object
    ## In fact, the `snap/1` driver returns the `Account` structure which is
    ## unwanted overhead, gere.
    accHash*: Hash256
    accBlob*: Blob

  AccountSlotsHeader* = object
    ## Storage root header
    accHash*: Hash256               ## Owner account, maybe unnecessary
    storageRoot*: Hash256           ## Start of storage tree
    subRange*: Option[NodeTagRange] ## Sub-range of slot range covered

  AccountStorageRange* = object
    ## List of storage descriptors, the last `AccountSlots` storage data might
    ## be incomplete and tthe `proof` is needed for proving validity.
    storages*: seq[AccountSlots]    ## List of accounts and storage data
    proof*: SnapStorageProof        ## Boundary proofs for last entry

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

proc read*(rlp: var Rlp, T: type NodeTag): T
    {.gcsafe, raises: [Defect,RlpError].} =
  rlp.read(Hash256).to(T)

proc append*(writer: var RlpWriter, nid: NodeTag) =
  writer.append(nid.to(Hash256))

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
  lrs.total == 0 and lrs.chunks == 0

proc isEmpty*(lrs: openArray[NodeTagRangeSet]): bool =
  ## Variant of `isEmpty()` where intervals are distributed across several
  ## sets.
  for ivSet in lrs:
    if 0 < ivSet.total or 0 < ivSet.chunks:
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

proc fullFactor*(lrs: openArray[NodeTagRangeSet]): float =
  ## Variant of `fullFactor()` where intervals are distributed across several
  ## sets. This function makes sense only if the interval sets are mutually
  ## disjunct.
  var accu: NodeTag
  for ivSet in lrs:
    if 0 < ivSet.total:
      if high(NodeTag) - ivSet.total < accu:
        return 1.0
      accu = accu + ivSet.total
    elif ivSet.chunks == 0:
      discard
    else: # number of points in `ivSet` is `2^256 + 1`
      return 1.0
  if accu == 0.to(NodeTag):
    return 0.0
  accu.u256.to(float) / (2.0^256)

# ------------------------------------------------------------------------------
# Public functions: printing & pretty printing
# ------------------------------------------------------------------------------

proc `$`*(nt: NodeTag): string =
  if nt == high(NodeTag):
    "high(NodeTag)"
  elif nt == 0.u256.NodeTag:
    "0"
  else:
    nt.to(Hash256).data.toHex

proc leafRangePp*(a, b: NodeTag): string =
  ## Needed for macro generated DSL files like `snap.nim` because the
  ## `distinct` flavour of `NodeTag` is discarded there.
  result = "[" & $a
  if a != b:
    result &= ',' & $b
  result &= "]"

proc `$`*(a, b: NodeTag): string =
  ## Prettyfied prototype
  leafRangePp(a,b)

proc `$`*(iv: NodeTagRange): string =
  leafRangePp(iv.minPt, iv.maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
