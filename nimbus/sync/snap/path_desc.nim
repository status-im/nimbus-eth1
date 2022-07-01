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
  std/[math, sequtils, strutils, hashes],
  eth/common/eth_types,
  nimcrypto/keccak,
  stew/[byteutils, interval_set],
  stint,
  ../../constants,
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

  PathSegment* = object
    ## Path prefix or trailer for an interior node in a hexary trie. See also
    ## the implementation of `NibblesSeq` from `eth/trie/nibbles` for a more
    ## general implementation.
    bytes: seq[byte]       ## <tag> + at most 32 bytes (aka 64 nibbles)

  PathSegmentError = enum
    isNoError = 0
    isTooLongEvenLength    ## More than 64 nibbles (even number)
    isTooLongOddLength     ## More than 63 nibbles (odd number)
    isUnknownType          ## Unknown encoduing type

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc to*(nid: NodeTag; T: type Hash256): T =
  result.data = nid.UInt256.toBytesBE

proc to*(nid: NodeTag; T: type NodeHash): T =
  nid.to(Hash256).T

proc to*(h: Hash256; T: type NodeTag): T =
  UInt256.fromBytesBE(h.data).T

proc to*(nh: NodeHash; T: type NodeTag): T =
  nh.Hash256.to(T)

proc to*(n: SomeUnsignedInt|UInt256; T: type NodeTag): T =
  n.u256.T

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(T: type NodeHash; ps: PathSegment): T =
  ## Import `PathSegment` argument into a `LeafTtemData`. Missing nibbles on the
  ## right will be zero padded.
  if (ps.bytes[0] and 0x10) == 0:
    for n in 1 ..< ps.bytes.len:
      result.Hash256.data[n-1] = ps.bytes[n]
  else:
    for n in 0 ..< ps.bytes.len:
      result.Hash256.data[n] = (ps.bytes[n] shl 4) or (ps.bytes[n+1] shr 4)

proc new*(T: type NodeTag; ps: PathSegment): T =
  ## Import `PathSegment` argument into a `LeafTtem`. Missing nibbles on the
  ## right will be zero padded.
  NodeHash.new(ps).to(NodeTag)

proc init*(nh: var NodeHash; data: openArray[byte]): bool =
  ## Import argument `data` into `nh` which must have length either `32` or `0`.
  ## The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    for n in 0 ..< 32:
      nh.Hash256.data[n] = data[n]
    return true
  elif data.len == 0:
    nh.reset
    return true

proc init*(nt: var NodeTag; data: openArray[byte]): bool =
  ## Similar to `init(li: var NodeTag; ps: PathSegment)`
  var h: NodeHash
  if h.init(data):
    nt = h.to(NodeTag)
    return true

proc init*(ps: var PathSegment; data: openArray[byte]): bool =
  ## Import argument `data` into `ps` which must be a valid path as found
  ## in a trie extension or leaf node starting with:
  ## * 0x00, or 0x20: followed by at most 64 nibbles (i.e. by 32 bytes max),
  ##   Here, data path is made up of the at most 32 pairs of nibbles.
  ## * 0x1x, or 0x3x: followed by at most 62 nibbles (31 bytes max). Here the
  ##   data path value starts with the `x` followed by the at most 62 pairs of
  ##   nibbles.
  if 0 < data.len:
    # Check first byte for marker
    if ((data[0] and 0xdf) == 0x00 and data.len <= 33) or # right nibble 0
       ((data[0] and 0xd0) == 0x10 and data.len <= 32):   # right nibble 1st dgt
      ps.bytes = data.toSeq
      return true

proc new*(T: type PathSegment; tag: NodeTag; isLeaf = false): T =
  ## Create `PathSegment` from `NodeTag`. If the `isLeaf` argument is set, the
  ## path segment is marked as a leaf node (trie prefix' 0x20').
  result.bytes = @[0.byte] & tag.to(Hash256).data.toSeq

# ------------------------------------------------------------------------------
# Public `PathSegment` functions
# ------------------------------------------------------------------------------

proc verify*(ps: PathSegment): Result[void,PathSegmentError] =
  ## Check `ip` for consistency
  if ps.bytes.len == 0:
    return ok()
  if (ps.bytes[0] and 0xdf) == 0:
    if 33 < ps.bytes.len:
      return err(isTooLongEvenLength)
  elif (ps.bytes[0] and 0xd0) == 0x10:
    if 32 < ps.bytes.len:
      return err(isTooLongOddLength)
  else:
    return err(isUnknownType)
  ok()

proc len*(ps: PathSegment): int =
  ## Returns the number of nibbles in the range 0..64.
  if ps.bytes.len == 0:
    0
  elif (ps.bytes[0] and 0x10) == 0:
    2 * ps.bytes.len - 2
  else:
    2 * ps.bytes.len - 1

proc setLen*(ps: var PathSegment; newLen: int) =
  ## Truncate or extend the length (i.e. the number of nibbles) of the argument
  ## `ip` to `newLen` bertwwn 0..63. When extending, new nibbles are zero
  ## initialised.
  ## This function throws an assertion defect if the `newLen` argument is
  ## outside the range 0..64.
  doAssert 0 <= newLen and newLen <= 64
  if ps.bytes.len == 0:
    ps.bytes = @[0.byte]
  if (ps.bytes[0] and 0x10) == 0:
    if (newLen and 1) == 0:          # both, old and new lengths are even
      ps.bytes.setLen(1 + (newLen shr 1))
    else:                            # new length odd, need to shift nibbles
      let newBytesLen = (newLen + 1) shr 1
      ps.bytes[0] = ps.bytes[0] or 0x10
      if 1 < ps.bytes.len:
        ps.bytes[0] = ps.bytes[0] or (ps.bytes[1] shr 4)
        for n in 1 ..< min(ps.bytes.len-1, newBytesLen):
          ps.bytes[n] = (ps.bytes[n] shl 4) or (ps.bytes[n+1] shr 4)
      ps.bytes.setLen(newBytesLen)
  else:
    if (newLen and 1) == 1:          # both, old and new lengths are odd
      ps.bytes.setLen((newLen + 1) shr 1)
    else:                            # new even length => shift nibbles right
      let oldBytesLen = ps.bytes.len
      ps.bytes.setLen((newLen shr 1) + 1)
      for n in countDown(min(ps.bytes.len-1,oldBytesLen),1):
        ps.bytes[n] = (ps.bytes[n-1] shl 4) or (ps.bytes[n] shr 4)
      ps.bytes[0] = ps.bytes[0] and 0xd0

proc `[]`*(ps: PathSegment; nibbleInx: int): int =
  ## Extract the nibble (aka hex digit) value at the argument position index
  ## `nibbleInx`. If the position index `nibbleInx` does not relate to a valid
  ## nibble position, `0` is returned
  ##
  ## This function throws an assertion defect if the `nibbleInx` is outside
  ## the range 0..63.
  doAssert 0 <= nibbleInx and nibbleInx < 64
  if ps.bytes.len == 0:
    result = 0
  elif (ps.bytes[0] and 0x10) == 0:
    let byteInx = (nibbleInx shr 1) + 1
    if (nibbleInx and 1) == 0:
      result = ps.bytes[byteInx].int shr 4
    else:
      result = ps.bytes[byteInx].int and 0x0f
  else:
    let byteInx = (nibbleInx + 1) shr 1
    if (nibbleInx and 1) == 0:
      result = ps.bytes[byteInx].int and 0x0f
    else:
      result = ps.bytes[byteInx].int shr 4

proc `[]=`*(ps: var PathSegment; nibbleInx: int; value: int) =
  ## Assign a nibble (aka hex) value `value` at position `nibbleInx`. If the
  ## length of the argument `ip` was smaller than the `nibbleInx`, the length
  ## will be extended to include that nibble.
  ##
  ## This function throws an assertion defect if the `nibbleInx` is outside
  ## the range 0..63, or if `value` is outside 0..15.
  doAssert 0 <= nibbleInx and nibbleInx < 64
  doAssert 0 <= value and value < 16
  if ps.len <= nibbleInx:
    if ps.bytes.len == 0:
      ps.bytes = @[0.byte]
    ps.setLen(nibbleInx + 1)
  if (ps.bytes[0] and 0x10) == 0:
    let byteInx = (nibbleInx shr 1) + 1
    if (nibbleInx and 1) == 0:
      ps.bytes[byteInx] = (value.uint8 shl 4) or (ps.bytes[byteInx] and 0x0f)
    else:
      ps.bytes[byteInx] = (ps.bytes[byteInx] and 0xf0) or value.uint8
  else:
    let byteInx = (nibbleInx + 1) shr 1
    if (nibbleInx and 1) == 0:
      ps.bytes[byteInx] = (ps.bytes[byteInx] and 0xf0) or value.uint8
    else:
      ps.bytes[byteInx] = (value.uint8 shl 4) or (ps.bytes[byteInx] and 0x0f)

proc `$`*(ps: PathSegment): string =
  $ps.len & "#" & ps.bytes.mapIt(it.toHex(2)).join.toLowerAscii

# ------------------------------------------------------------------------------
# Public rlp support
# ------------------------------------------------------------------------------

proc read*(rlp: var Rlp, T: type NodeTag): T
    {.gcsafe, raises: [Defect,RlpError]} =
  rlp.read(Hash256).to(T)

proc append*(writer: var RlpWriter, nid: NodeTag) =
  writer.append(nid.to(Hash256))

# -------------

proc snapRead*(rlp: var Rlp; T: type Account; strict: static[bool] = false): T
    {.gcsafe, raises: [Defect, RlpError]} =
  ## RLP decoding for `Account`. The `snap` RLP representation of the account
  ## differs from standard `Account` RLP. Empty storage hash and empty code
  ## hash are each represented by an RLP zero-length string instead of the
  ## full hash.
  ##
  ## Normally, this read function will silently handle standard encodinig and
  ## `snap` enciding. Setting the argument strict as `false` the function will
  ## throw an exception if `snap` encoding is violated.
  rlp.tryEnterList()
  result.nonce = rlp.read(typeof(result.nonce))
  result.balance = rlp.read(typeof(result.balance))
  if rlp.blobLen != 0 or not rlp.isBlob:
    result.storageRoot = rlp.read(typeof(result.storageRoot))
    when strict:
      if result.storageRoot == BLANK_ROOT_HASH:
        raise newException(RlpTypeMismatch,
          "BLANK_ROOT_HASH not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.storageRoot = BLANK_ROOT_HASH
  if rlp.blobLen != 0 or not rlp.isBlob:
    result.codeHash = rlp.read(typeof(result.codeHash))
    when strict:
      if result.codeHash == EMPTY_SHA3:
        raise newException(RlpTypeMismatch,
          "EMPTY_SHA3 not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.codeHash = EMPTY_SHA3

proc snapAppend*(writer: var RlpWriter; account: Account) =
  ## RLP encoding for `Account`. The snap RLP representation of the account
  ## differs from standard `Account` RLP. Empty storage hash and empty code
  ## hash are each represented by an RLP zero-length string instead of the
  ## full hash.
  writer.startList(4)
  writer.append(account.nonce)
  writer.append(account.balance)
  if account.storageRoot == BLANK_ROOT_HASH:
    writer.append("")
  else:
    writer.append(account.storageRoot)
  if account.codeHash == EMPTY_SHA3:
    writer.append("")
  else:
    writer.append(account.codeHash)

# -------------

proc compactRead*(rlp: var Rlp, T: type PathSegment): T
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Read compact encoded path segment
  rlp.tryEnterList()
  let
    path = rlp.read(array[32, byte])
    length = rlp.read(byte)
  if 64 < length:
    raise newException(
      MalformedRlpError, "More the most 64 nibbles for PathSegment")
  if (length and 1) == 0:
    # initalise as even extension
    result.bytes.setLen(1 + (length shr 1))
    for n in 1 ..< result.bytes.len:
      result.bytes[n] = path[n-1]
  else:
    # initalise as odd extension
    result.bytes.setLen((length + 1) shr 1)
    result.bytes[0] = 0x10 or (path[0] shl 4)
    for n in 1 ..< result.bytes.len:
      result.bytes[n] = (path[n-1] shl 4) or (path[n] shr 4)

proc compactAppend*(writer: var RlpWriter, ps: PathSegment) =
  ## Append compact encoded path segment
  var path: array[32, byte]
  if (ps.bytes[0] and 0x10) == 0:
    for n in 1 ..< ps.bytes.len:
      path[n-1] = ps.bytes[n]
  else:
    for n in 1 ..< ps.bytes.len:
      path[n-1] = (ps.bytes[n-1] shl 4) or (ps.bytes[n] shr 4)
    path[ps.bytes.len-1] = ps.bytes[^1] shl 4
  writer.startList(2)
  writer.append(path)
  writer.append(ps.len.byte)

# -------------

proc dbRead*(rlp: var Rlp, T: type PathSegment): T
    {.gcsafe, raises: [Defect,RlpError]} =
  ## Read as stored in the database
  result.bytes = rlp.read(Blob)

proc dbAppend*(writer: var RlpWriter, ps: PathSegment) =
  ## Append in database record format
  writer.append(ps.bytes)

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
    1.0
  else:
    0.0

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
