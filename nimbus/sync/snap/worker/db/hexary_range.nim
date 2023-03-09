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
    base*: NodeTag              ## No node between `base` and `leafs[0]`
    leafs*: seq[RangeLeaf]      ## List of consecutive leaf nodes
    leafsSize*: int             ## RLP encoded size of `leafs` on wire
    proof*: seq[SnapProof]      ## Boundary proof
    proofSize*: int             ##  RLP encoded size of `proof` on wire

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
    nodeTag: NodeTag;                # Left boundary
    rootKey: NodeKey|RepairKey;      # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): HashSet[SnapProof]
      {.gcsafe, raises: [CatchableError]} =
  ## Helper for `updateProof()`
  nodeTag
    .hexaryPath(rootKey, db)
    .path
    .mapIt(it.node)
    .filterIt(it.kind != Leaf)
    .mapIt(it.convertTo(Blob).to(SnapProof))
    .toHashSet

proc allPathNodes(
    nodeTag: NodeTag;                # Left boundary
    rootKey: NodeKey|RepairKey;      # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): HashSet[SnapProof]
      {.gcsafe, raises: [CatchableError]} =
  ## Helper for `updateProof()`
  nodeTag
    .hexaryPath(rootKey, db)
    .path
    .mapIt(it.node)
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
      ): auto =
  ## Collect trie database leafs prototype. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var rc: Result[RangeProof,HexaryError]

  block body:
    let
      nodeMax = maxPt(iv) # `inject` is for debugging (if any)
    var
      nodeTag = minPt(iv)
      prevTag: NodeTag
      rls: RangeProof

    # Set up base node, the nearest node before `iv.minPt`
    block:
      let rx = nodeTag.hexaryPath(rootKey,db).hexaryNearbyLeft(db)
      if rx.isOk:
        rls.base = getPartialPath(rx.value).convertTo(NodeKey).to(NodeTag)
      elif rx.error != NearbyFailed:
        rc = typeof(rc).err(rx.error)
        break body

    # Fill leaf nodes from interval range unless size reached
    while nodeTag <= nodeMax:
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
      if rightTag <= prevTag and 0 < rls.leafs.len:
        # Oops, should have been tackeled by `hexaryNearbyRight()`
        rc = typeof(rc).err(FailedNextNode)
        break body # stop here

      let (pairLen,listLen) =
        hexaryRangeRlpLeafListSize(xPath.leafData.len, rls.leafsSize)

      if listLen < nSizeLimit:
        rls.leafsSize += pairLen
      else:
        break

      rls.leafs.add RangeLeaf(
        key:  rightKey,
        data: xPath.leafData)

      prevTag = nodeTag
      nodeTag = rightTag + 1.u256
      # End loop

    # Count outer RLP wrapper
    if 0 < rls.leafs.len:
      rls.leafsSize = hexaryRangeRlpSize rls.leafsSize

    rc = typeof(rc).ok(rls)
    # End body

  rc


template updateProof(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey|RepairKey;      # State root
    rls: RangeProof;                 # Set of collected leafs and a `base`
      ): auto =
  ## Complement leafs list by adding proof nodes. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var proof = allPathNodes(rls.base, rootKey, db)
  if 0 < rls.leafs.len:
    proof.incl nonLeafPathNodes(rls.leafs[^1].key.to(NodeTag), rootKey, db)

  var rp = rls
  rp.proof = toSeq(proof)
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
  let rc = db.collectLeafs(rootKey, iv, nSizeLimit)
  if rc.isErr:
    err(rc.error)
  else:
    ok(db.updateProof(rootKey, rc.value))

proc hexaryRangeLeafsProof*(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey;                # State root
    rp: RangeProof;                  # Set of collected leafs and a `base`
      ): RangeProof
      {.gcsafe, raises: [CatchableError]} =
  ## Complement leafs list by adding proof nodes to the argument list
  ## `leafList`.
  db.updateProof(rootKey, rp)

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
