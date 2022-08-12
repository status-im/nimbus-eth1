# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module is sort of a customised rewrite of the function
## `eth/trie/hexary.getAux()`, `getkeysAux()`, etc.

import
  std/sequtils,
  chronicles,
  eth/[common/eth_types, trie/nibbles],
  ./hexary_desc

{.push raises: [Defect].}

const
  HexaryFollowDebugging = false or true

type
  HexaryGetFn* = proc(key: Blob): Blob {.gcsafe.}
    ## Fortesting/debugging: database get() function

# ------------------------------------------------------------------------------
# Public walk along hexary trie records
# ------------------------------------------------------------------------------

proc hexaryFollow*(
    db: HexaryTreeDB;
    root: NodeKey;
    path: NibblesSeq;
    getFn: HexaryGetFn
      ): (int, bool, Blob)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Returns the number of matching digits/nibbles from the argument `path`
  ## found in the proofs trie.
  let
    nNibbles = path.len
  var
    inPath = path
    recKey = root.ByteArray32.toSeq
    leafBlob: Blob
    emptyRef = false

  when HexaryFollowDebugging:
    trace "follow", rootKey=root.to(RepairKey).pp(db), path

  while true:
    let value = recKey.getFn()
    if value.len == 0:
      break

    var nodeRlp = rlpFromBytes value
    case nodeRlp.listLen:
    of 2:
      let
        (isLeaf, pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        sharedNibbles = inPath.sharedPrefixLen(pathSegment)
        fullPath = sharedNibbles == pathSegment.len
        inPathLen = inPath.len
      inPath = inPath.slice(sharedNibbles)

      # Leaf node
      if isLeaf:
        let leafMode = sharedNibbles == inPathLen
        if fullPath and leafMode:
          leafBlob = nodeRlp.listElem(1).toBytes
        when HexaryFollowDebugging:
          let nibblesLeft = inPathLen - sharedNibbles
          trace "follow leaf",
            fullPath, leafMode, sharedNibbles, nibblesLeft,
            pathSegment, newPath=inPath
        break

      # Extension node
      if fullPath:
        let branch = nodeRlp.listElem(1)
        if branch.isEmpty:
          when HexaryFollowDebugging:
            trace "follow extension", newKey="n/a"
          emptyRef = true
          break
        recKey = branch.toBytes
        when HexaryFollowDebugging:
          trace "follow extension",
            newKey=recKey.convertTo(RepairKey).pp(db), newPath=inPath
      else:
        when HexaryFollowDebugging:
          trace "follow extension",
            fullPath, sharedNibbles, pathSegment, inPathLen, newPath=inPath
        break

    of 17:
      # Branch node
      if inPath.len == 0:
        leafBlob = nodeRlp.listElem(1).toBytes
        break
      let
        inx = inPath[0].int
        branch = nodeRlp.listElem(inx)
      if branch.isEmpty:
        when HexaryFollowDebugging:
          trace "follow branch", newKey="n/a"
        emptyRef = true
        break
      inPath = inPath.slice(1)
      recKey = branch.toBytes
      when HexaryFollowDebugging:
        trace "follow branch",
          newKey=recKey.convertTo(RepairKey).pp(db), inx, newPath=inPath

    else:
      when HexaryFollowDebugging:
        trace "follow oops",
          nColumns = nodeRlp.listLen
      break

  # end while

  let pathLen = nNibbles - inPath.len

  when HexaryFollowDebugging:
    trace "follow done",
      recKey, emptyRef, pathLen, leafSize=leafBlob.len

  (pathLen, emptyRef, leafBlob)


proc hexaryFollow*(
    db: HexaryTreeDB;
    root: NodeKey;
    path: NodeKey;
    getFn: HexaryGetFn;
      ): (int, bool, Blob)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `hexaryFollow()`
  db.hexaryFollow(root, path.to(NibblesSeq), getFn)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
