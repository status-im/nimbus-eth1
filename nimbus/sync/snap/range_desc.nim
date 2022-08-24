# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[math, hashes],
  eth/common/eth_types,
  nimcrypto/keccak,
  stew/[byteutils, interval_set],
  stint,
  ../../constants,
  ../protocol,
  ../types

{.push raises: [Defect].}

type
  NodeTag* = ##\
    ## Trie leaf item, account hash etc.
    distinct UInt256

  LeafRange* = ##\
    ## Interval `[minPt,maxPt]` of` NodeTag` elements, can be managed in an
    ## `IntervalSet` data type.
    Interval[NodeTag,UInt256]

  LeafRangeSet* = ##\
    ## Managed structure to handle non-adjacent `LeafRange` intervals
    IntervalSetRef[NodeTag,UInt256]

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

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc to*(nid: NodeTag; T: type Hash256): T =
  ## Convert to serialised equivalent
  result.data = nid.UInt256.toBytesBE

proc to*(nid: NodeTag; T: type NodeHash): T =
  ## Syntactic sugar
  nid.to(Hash256).T

proc to*(h: Hash256; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(h.data).T

proc to*(nh: NodeHash; T: type NodeTag): T =
  ## Syntactic sugar
  nh.Hash256.to(T)

proc to*(n: SomeUnsignedInt|UInt256; T: type NodeTag): T =
  ## Syntactic sugar
  n.u256.T

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc init*(nh: var NodeHash; data: openArray[byte]): bool =
  ## Import argument `data` into `nh` which must have length either `32` or `0`.
  ## The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    (addr nh.Hash256.data[0]).copyMem(unsafeAddr data[0], 32)
    return true
  elif data.len == 0:
    nh.reset
    return true

proc init*(nt: var NodeTag; data: openArray[byte]): bool =
  ## Similar to `init(nh: var NodeHash; .)`.
  var h: NodeHash
  if h.init(data):
    nt = h.to(NodeTag)
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
# Public `NodeTag` and `LeafRange` functions
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
  keccak256.digest(data).to(T)

proc freeFactor*(lrs: LeafRangeSet): float =
  ## Free factor, ie. `#items-free / 2^256` to be used in statistics
  if 0 < lrs.total:
    ((high(NodeTag) - lrs.total).u256 + 1).to(float) / (2.0^256)
  elif lrs.chunks == 0:
    1.0 # `total` represents the residue class `mod 2^256` from `0`..`(2^256-1)`
  else:
    0.0

proc fullFactor*(lrs: LeafRangeSet): float =
  ## Free factor, ie. `#items-contained / 2^256` to be used in statistics
  if 0 < lrs.total:
    lrs.total.u256.to(float) / (2.0^256)
  elif lrs.chunks == 0:
    0.0
  else:
    1.0 # `total` represents the residue class `mod 2^256` from `0`..`(2^256-1)`

# Printing & pretty printing
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

proc `$`*(iv: LeafRange): string =
  leafRangePp(iv.minPt, iv.maxPt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
