# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[sequtils, sets, tables],
  chronicles,
  eth/[common, p2p, rlp, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_nearby, hexary_paths]

{.push raises: [].}

type
  RangeLeaf* = object
    key*: NodeKey ## Leaf node path
    data*: Blob   ## Leaf node data

  RangeProof* = object
    leafs*: seq[RangeLeaf]
    proof*: seq[Blob]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use (if at all, unless debugging)
  (addr result.ByteArray32[0]).copyMem(unsafeAddr key.ByteArray33[1], 32)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template collectLeafs(
    iv: NodeTagRange;                # Proofed range of leaf paths
    rootKey: NodeKey|RepairKey;      # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
    nLeafs: int;                     # Implies maximal data size
      ): auto =
  ## Collect trie database leafs prototype. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var rc: Result[seq[RangeLeaf],HexaryError]

  block body:
    var
      nodeTag = iv.minPt
      prevTag: NodeTag
      rls: seq[RangeLeaf]

    # Fill at most `nLeafs` leaf nodes from interval range
    while rls.len < nLeafs and nodeTag <= iv.maxPt:
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
        rightKey = xPath.getPartialPath.convertTo(NodeKey)
        rightTag = rightKey.to(NodeTag)

      # Prevents from semi-endless looping
      if rightTag <= prevTag and 0 < rls.len:
        # Oops, should have been tackeled by `hexaryNearbyRight()`
        rc = typeof(rc).err(FailedNextNode)
        break body # stop here

      rls.add RangeLeaf(
        key:  rightKey,
        data: xPath.leafData)

      prevTag = nodeTag
      nodeTag = rightTag + 1.u256

    rc = typeof(rc).ok(rls)
    # End body

  rc


template updateProof(
    baseTag: NodeTag;                # Left boundary
    leafList: seq[RangeLeaf];        # Set of collected leafs
    rootKey: NodeKey|RepairKey;      # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): auto =
  ## Update leafs list by adding proof nodes. This directive is provided as
  ## `template` for avoiding varying exceprion annotations.
  var proof = baseTag.hexaryPath(rootKey, db)
        .path
        .mapIt(it.node)
        .filterIt(it.kind != Leaf)
        .mapIt(it.convertTo(Blob))
        .toHashSet
  if 0 < leafList.len:
    proof.incl leafList[^1].key.to(NodeTag).hexaryPath(rootKey, db)
        .path
         .mapIt(it.node)
        .filterIt(it.kind != Leaf)
        .mapIt(it.convertTo(Blob))
        .toHashSet

  RangeProof(
    leafs: leafList,
    proof: proof.toSeq)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryRangeLeafsProof*(
    iv: NodeTagRange;                # Proofed range of leaf paths
    rootKey: NodeKey;                # State root
    db: HexaryGetFn;                 # Database abstraction
    nLeafs = high(int);              # Implies maximal data size
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [Defect,RlpError]} =
  ## ...
  let rc = iv.collectLeafs(rootKey, db, nLeafs)
  if rc.isErr:
    err(rc.error)
  else:
    ok(iv.minPt.updateProof(rc.value, rootKey, db))

proc hexaryRangeLeafsProof*(
    baseTag: NodeTag;                # Left boundary
    leafList: seq[RangeLeaf];        # Set of already collected leafs
    rootKey: NodeKey;                # State root
    db: HexaryGetFn;                 # Database abstraction
      ): RangeProof
      {.gcsafe, raises: [Defect,RlpError]} =
  ## ...
  baseTag.updateProof(leafList, rootKey, db)


proc hexaryRangeLeafsProof*(
    iv: NodeTagRange;                # Proofed range of leaf paths
    rootKey: NodeKey;                # State root
    db: HexaryTreeDbRef;             # Database abstraction
    nLeafs = high(int);              # Implies maximal data size
      ): Result[RangeProof,HexaryError]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## ...
  let rc = iv.collectLeafs(rootKey, db, nLeafs)
  if rc.isErr:
    err(rc.error)
  else:
    ok(iv.minPt.updateProof(rc.value, rootKey, db))

proc hexaryRangeLeafsProof*(
    baseTag: NodeTag;                # Left boundary
    leafList: seq[RangeLeaf];        # Set of already collected leafs
    rootKey: NodeKey;                # State root
    db: HexaryTreeDbRef;             # Database abstraction
      ): RangeProof
      {.gcsafe, raises: [Defect,KeyError]} =
  ## ...
  baseTag.updateProof(leafList, rootKey, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
