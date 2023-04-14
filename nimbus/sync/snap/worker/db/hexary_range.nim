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
  chronos,
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
    leafsLast*: bool            ## If no leaf exceeds `max(base,leafs[])`
    leafsSize*: int             ## RLP encoded size of `leafs` on wire
    proof*: seq[SnapProof]      ## Boundary proof
    proofSize*: int             ##  RLP encoded size of `proof` on wire

const
  proofNodeSizeMax = 532
    ## Branch node with all branches `high(UInt256)` within RLP list

  veryLongDuration = 60.weeks
    ## Longer than any collection of data will probably take

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

proc timeIsOver(stopAt: Moment): bool =
  ## Helper (avoids `chronos` import when running generic function)
  stopAt <= chronos.Moment.now()

proc stopAt(timeout: chronos.Duration): Moment =
  ## Helper (avoids `chronos` import when running generic function)
  chronos.Moment.now() + timeout

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
    stopAt: Moment;                  # limit search time
      ): auto =
  ## Collect trie database leafs prototype. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var
    rc: Result[RangeProof,HexaryError]
    ttd = stopAt
  block body:
    let
      nodeMax = maxPt(iv) # `inject` is for debugging (if any)
    var
      nodeTag = minPt(iv)
      prevTag: NodeTag
      rls: RangeProof

    # Set up base node, the nearest node before `iv.minPt`
    if 0.to(NodeTag) < nodeTag:
      let rx = nodeTag.hexaryNearbyLeft(rootKey, db)
      if rx.isOk:
        rls.base = rx.value
      elif rx.error != NearbyBeyondRange:
        rc = typeof(rc).err(rx.error)
        break body

    # Fill leaf nodes (at least one) from interval range unless size reached
    while nodeTag <= nodeMax or rls.leafs.len == 0:
      # The following logic might be sub-optimal. A strict version of the
      # `next()` function that stops with an error at dangling links could
      # be faster if the leaf nodes are not too far apart on the hexary trie.
      let
        xPath = block:
          let rx = nodeTag.hexaryPath(rootKey,db).hexaryNearbyRight(db)
          if rx.isErr:
            if rx.error != NearbyBeyondRange:
              rc = typeof(rc).err(rx.error)
            else:
              rls.leafsLast = true
              rc = typeof(rc).ok(rls) # done ok, last node reached
            break body
          rx.value
        rightKey = getPartialPath(xPath).convertTo(NodeKey)
        rightTag = rightKey.to(NodeTag)

      # Prevents from semi-endless looping
      if rightTag <= prevTag and 0 < rls.leafs.len:
        # Oops, should have been tackled by `hexaryNearbyRight()`
        rc = typeof(rc).err(FailedNextNode)
        break body # stop here

      let (pairLen,listLen) =
        hexaryRangeRlpLeafListSize(xPath.leafData.len, rls.leafsSize)

      if listLen <= nSizeLimit:
        rls.leafsSize += pairLen
      else:
        break # collected enough

      rls.leafs.add RangeLeaf(
        key:  rightKey,
        data: xPath.leafData)

      if timeIsOver(ttd):
        break # timout

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
  var rp = rls

  if 0.to(NodeTag) < rp.base or not rp.leafsLast:
    var proof = allPathNodes(rls.base, rootKey, db)
    if 0 < rls.leafs.len:
      proof.incl nonLeafPathNodes(rls.leafs[^1].key.to(NodeTag), rootKey, db)

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
    timeout = veryLongDuration;      # Limit retrieval time
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Collect trie database leafs prototype and add proof.
  let rc = db.collectLeafs(rootKey, iv, nSizeLimit, stopAt(timeout))
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


proc hexaryRangeInflate*(
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    rootKey: NodeKey;                # State root
    nodeKey: NodeTag;                # Centre of inflated interval
      ): NodeTagRange
      {.gcsafe, raises: [CatchableError]} =
  ## Calculate the largest leaf range interval containing only the argument
  ## `nodeKey`.
  ##
  ## If the database is fully allocated, then the returned interval ends right
  ## before or after the next neighbour leaf node, or at the range type
  ## boundaries `low(NodeTag)` or `high(NodeTag)`.
  ##
  ## If the database is partially allocated only and some of the neighbour
  ## nodes are missing, the returned interval is not extended towards this
  ## end.
  var
    leftPt = nodeKey
    rightPt = nodeKey

  if low(NodeTag) < nodeKey:
    let
      pt = nodeKey - 1.u256
      rc = pt.hexaryPath(rootKey,db).hexaryNearbyLeft(db)
    if rc.isOk:
      leftPt = rc.value.getPartialPath.convertTo(NodeKey).to(NodeTag) + 1.u256
    elif rc.error == NearbyBeyondRange:
      leftPt = low(NodeTag)

  if nodeKey < high(NodeTag):
    let
      pt = nodeKey + 1.u256
      rc = pt.hexaryPath(rootKey,db).hexaryNearbyRight(db)
    if rc.isOk:
      rightPt = rc.value.getPartialPath.convertTo(NodeKey).to(NodeTag) - 1.u256
    elif rc.error == NearbyBeyondRange:
      rightPt = high(NodeTag)

  NodeTagRange.new(leftPt, rightPt)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

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

proc hexaryRangeRlpNodesListSizeMax*(n: int): int =
  ## Maximal size needs to RLP encode `n` nodes (handy for calculating the
  ## space needed to store proof nodes.)
  const nMax = high(int) div proofNodeSizeMax
  if n <= nMax:
    hexaryRangeRlpSize(n * proofNodeSizeMax)
  else:
    high(int)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
