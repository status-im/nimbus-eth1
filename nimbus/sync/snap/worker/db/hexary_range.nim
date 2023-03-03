# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets, tables],
  chronicles,
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../../protocol,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_nearby, hexary_paths]

type
  RangeLeaf* = object
    key*: NodeKey ## Leaf node path
    data*: Blob   ## Leaf node data

  RangeProof* = object
    leafs*: seq[RangeLeaf]
    leafsSize*: int
    proof*: seq[SnapProof]
    proofSize*: int

proc hexaryRangeRlpLeafListSize*(blobLen: int; lstLen = 0): (int,int) {.gcsafe.}
proc hexaryRangeRlpSize*(blobLen: int): int {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use (if at all, unless debugging)
  (addr result.ByteArray32[0]).copyMem(unsafeAddr key.ByteArray33[1], 32)

proc rlpPairSize(aLen: int; bRlpLen: int): int =
  ## Size caclualation for an RLP encoded pair `[<a>,<rb>]` for blobs `a` and
  ## rlp encoded `rb` argument length `aLen` and `bRlpLen`.
  let aRlpLen = hexaryRangeRlpSize(aLen)
  if bRlpLen < high(int) - aRlpLen:
    hexaryRangeRlpSize(aRlpLen + bRlpLen)
  else:
    high(int)

proc nonLeafPathNodes(
    baseTag: NodeTag;                # Left boundary
    rootKey: NodeKey|RepairKey;      # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): HashSet[SnapProof]
      {.gcsafe, raises: [CatchableError]} =
  ## Helper for `updateProof()`
  baseTag
    .hexaryPath(rootKey, db)
    .path
    .mapIt(it.node)
    .filterIt(it.kind != Leaf)
    .mapIt(it.convertTo(Blob).to(SnapProof))
    .toHashSet

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template collectLeafs(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey|RepairKey;      # State root
    iv: NodeTagRange;                # Proofed range of leaf paths
    nSizeLimit: int;                 # List of RLP encoded data must be smaller
    nSizeUsed: var int;              # Updated size counter for the raw list
      ): auto =
  ## Collect trie database leafs prototype. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var rc: Result[seq[RangeLeaf],HexaryError]

  block body:
    var
      nodeTag = minPt(iv)
      prevTag: NodeTag
      rls: seq[RangeLeaf]

    # Fill leaf nodes from interval range unless size reached
    while nodeTag <= maxPt(iv):
      # The following logic might be sub-optimal. A strict version of the
      # `next()` function that stops with an error at dangling links could
      # be faster if the leaf nodes are not too far apart on the hexary trie.
      var
        xPath = block:
          let rx = nodeTag.hexaryPath(rootKey,db).hexaryNearbyRight(db)
          if rx.isErr:
            rc = typeof(rc).err(rx.error)
            break body
          rx.value
        rightKey = getPartialPath(xPath).convertTo(NodeKey)
        rightTag = rightKey.to(NodeTag)

      # Prevents from semi-endless looping
      if rightTag <= prevTag and 0 < rls.len:
        # Oops, should have been tackeled by `hexaryNearbyRight()`
        rc = typeof(rc).err(FailedNextNode)
        break body # stop here

      let (pairLen,listLen) =
        hexaryRangeRlpLeafListSize(xPath.leafData.len, nSizeUsed)
      if listLen < nSizeLimit:
        nSizeUsed += pairLen
      else:
        break

      rls.add RangeLeaf(
        key:  rightKey,
        data: xPath.leafData)

      prevTag = nodeTag
      nodeTag = rightTag + 1.u256

    rc = typeof(rc).ok(rls)
    # End body

  rc


template updateProof(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey|RepairKey;      # State root
    baseTag: NodeTag;                # Left boundary
    leafList: seq[RangeLeaf];        # Set of collected leafs
    nSizeUsed: int;                  # To be stored into the result
      ): auto =
  ## Complement leafs list by adding proof nodes. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var proof = nonLeafPathNodes(baseTag, rootKey, db)
  if 0 < leafList.len:
    proof.incl nonLeafPathNodes(leafList[^1].key.to(NodeTag), rootKey, db)

  var rp = RangeProof(
    leafs: leafList,
    proof: toSeq(proof))

  if 0 < nSizeUsed:
    rp.leafsSize = hexaryRangeRlpSize nSizeUsed
  if 0 < rp.proof.len:
    rp.proofSize = hexaryRangeRlpSize rp.proof.foldl(a + b.to(Blob).len, 0)

  rp

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryRangeLeafsProof*(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey;                # State root
    iv: NodeTagRange;                # Proofed range of leaf paths
    nSizeLimit = high(int);          # List of RLP encoded data must be smaller
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Collect trie database leafs prototype and add proof.
  var accSize = 0
  let rc = db.collectLeafs(rootKey, iv, nSizeLimit, accSize)
  if rc.isErr:
    err(rc.error)
  else:
    ok(db.updateProof(rootKey, iv.minPt, rc.value, accSize))

proc hexaryRangeLeafsProof*(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey;                # State root
    baseTag: NodeTag;                # Left boundary
    leafList: seq[RangeLeaf];        # Set of already collected leafs
      ): RangeProof
      {.gcsafe, raises: [CatchableError]} =
  ## Complement leafs list by adding proof nodes to the argument list
  ## `leafList`.
  db.updateProof(rootKey, baseTag, leafList, 0)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc to*(
    rl: RangeLeaf;
    T: type SnapAccount;
      ): T
      {.gcsafe, raises: [RlpError]} =
  ## Convert the generic `RangeLeaf` argument to payload type.
  T(accHash: rl.key.to(Hash256),
    accBody: rl.data.decode(Account))


proc hexaryRangeRlpSize*(blobLen: int): int =
  ## Returns the size of RLP encoded <blob> of argument length `blobLen`.
  if blobLen < 56:
      return blobLen + 1
  if blobLen < (1 shl (8 * 1)):
    return blobLen + 2
  if blobLen < (1 shl (8 * 2)):
    return blobLen + 3
  if blobLen < (1 shl (8 * 3)):
    return blobLen + 4

  when sizeof(int) < 8:
    if blobLen < (1 shl (8 * 4)):
      return blobLen + 5
    if blobLen < (1 shl (8 * 5)):
      return blobLen + 6
    if blobLen < (1 shl (8 * 6)):
      return blobLen + 7
    if blobLen < (1 shl (8 * 7)):
      return blobLen + 8

  if blobLen < high(int) - (1 + sizeof(int)):
    blobLen + 1 + sizeof(int)
  else:
    high(int)

proc hexaryRangeRlpLeafListSize*(blobLen: int; lstLen = 0): (int,int) =
  ## Size caclualation for an RLP encoded list `[[<key>,<blob>],a,b,..]`
  ## where a,b,.. are from a sequence of the same format `[<keyA>,<blobA>]`,
  ## `[<keyB>,<blobB>]`,... The size of blob is the argument size `blobLen`,
  ## and the toral size of the sequence is `listLen`.
  ##
  ## The fuction returns `(x,y)`, the size `x` of the RLP encoded pair
  ## `[<key>,<blob>]` and the total size `y` of the complete RLP encoded list
  ## `[[<key>,<blob>],a,b,..]`.
  let pairLen = blobLen.rlpPairSize(33)
  if lstLen == 0:
    (pairLen, hexaryRangeRlpSize(pairLen))
  elif lstLen < high(int) - lstLen:
    (pairLen, hexaryRangeRlpSize(pairLen + lstLen))
  else:
    (pairLen, high(int))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
