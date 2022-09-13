# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Find node paths in hexary tries.

import
  std/[tables],
  eth/[common/eth_types_rlp, trie/nibbles],
  ../../range_desc,
  ./hexary_desc

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc pp(w: Blob; db: HexaryTreeDbRef): string =
  w.convertTo(RepairKey).pp(db)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getNibblesImpl(path: XPath; start = 0): NibblesSeq =
  ## Re-build the key path
  for n in start ..< path.path.len:
    let it = path.path[n]
    case it.node.kind:
    of Branch:
      result = result & @[it.nibble.byte].initNibbleRange.slice(1)
    of Extension:
      result = result & it.node.ePfx
    of Leaf:
      result = result & it.node.lPfx
  result = result & path.tail

proc toBranchNode(
    rlp: Rlp
      ): XNodeObj
      {.gcsafe, raises: [Defect,RlpError]} =
  var rlp = rlp
  XNodeObj(kind: Branch, bLink: rlp.read(array[17,Blob]))

proc toLeafNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [Defect,RlpError]} =
  XNodeObj(kind: Leaf, lPfx: pSegm, lData: rlp.listElem(1).toBytes)

proc toExtensionNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [Defect,RlpError]} =
  XNodeObj(kind: Extension, ePfx: pSegm, eLink: rlp.listElem(1).toBytes)

# not now  ...
when false:
  proc `[]`(path: XPath; n: int): XPathStep =
    path.path[n]

  proc `[]`(path: XPath; s: Slice[int]): XPath =
    XPath(path: path.path[s.a .. s.b], tail: path.getNibbles(s.b+1))

  proc len(path: XPath): int =
    path.path.len

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc pathExtend(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [Defect,KeyError].} =
  ## For the given path, extend to the longest possible repair tree `db`
  ## path following the argument `path.tail`.
  result = path
  var key = key
  while db.tab.hasKey(key) and 0 < result.tail.len:
    let node = db.tab[key]
    case node.kind:
    of Leaf:
      if result.tail.len == result.tail.sharedPrefixLen(node.lPfx):
        # Bingo, got full path
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        result.tail = EmptyNibbleRange
      return
    of Branch:
      let nibble = result.tail[0].int8
      if node.bLink[nibble].isZero:
        return
      result.path.add RPathStep(key: key, node: node, nibble: nibble)
      result.tail = result.tail.slice(1)
      key = node.bLink[nibble]
    of Extension:
      if node.ePfx.len != result.tail.sharedPrefixLen(node.ePfx):
        return
      result.path.add RPathStep(key: key, node: node, nibble: -1)
      result.tail = result.tail.slice(node.ePfx.len)
      key = node.eLink


proc pathExtend(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Ditto for `XPath` rather than `RPath`
  result = path
  var key = key

  while true:
    let value = key.getFn()
    if value.len == 0:
      return

    var nodeRlp = rlpFromBytes value
    case nodeRlp.listLen:
    of 2:
      let
        (isLeaf, pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        nSharedNibbles = result.tail.sharedPrefixLen(pathSegment)
        fullPath = (nSharedNibbles == pathSegment.len)
        newTail = result.tail.slice(nSharedNibbles)

      # Leaf node
      if isLeaf:
        let node = nodeRlp.toLeafNode(pathSegment)
        result.path.add XPathStep(key: key, node: node, nibble: -1)
        result.tail = newTail
        return

      # Extension node
      if fullPath:
        let node = nodeRlp.toExtensionNode(pathSegment)
        if node.eLink.len == 0:
          return
        result.path.add XPathStep(key: key, node: node, nibble: -1)
        result.tail = newTail
        key = node.eLink
      else:
        return

    of 17:
      # Branch node
      let node = nodeRlp.toBranchNode
      if result.tail.len == 0:
        result.path.add XPathStep(key: key, node: node, nibble: -1)
        return
      let inx = result.tail[0].int8
      if node.bLink[inx].len == 0:
        return
      result.path.add XPathStep(key: key, node: node, nibble: inx)
      result.tail = result.tail.slice(1)
      key = node.bLink[inx]
    else:
      return

    # end while
  # notreached


proc pathLeast(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## For the partial path given, extend by branch nodes with least node
  ## indices.
  result = path
  result.tail = EmptyNibbleRange
  result.depth = result.getNibblesImpl.len

  var
    key = key
    value = key.getFn()
  if value.len == 0:
    return

  while true:
    block loopContinue:
      let nodeRlp = rlpFromBytes value
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes

        # Leaf node
        if isLeaf:
          let node = nodeRlp.toLeafNode(pathSegment)
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          result.depth += pathSegment.len
          return # done ok

        let node = nodeRlp.toExtensionNode(pathSegment)
        if 0 < node.eLink.len:
          value = node.eLink.getFn()
          if 0 < value.len:
            result.path.add XPathStep(key: key, node: node, nibble: -1)
            result.depth += pathSegment.len
            key = node.eLink
            break loopContinue
      of 17:
        # Branch node
        let node = nodeRlp.toBranchNode
        if node.bLink[16].len != 0 and 64 <= result.depth:
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          return # done ok

        for inx in 0 .. 15:
          let newKey = node.bLink[inx]
          if 0 < newKey.len:
            value = newKey.getFn()
            if 0 < value.len:
              result.path.add XPathStep(key: key, node: node, nibble: inx.int8)
              result.depth.inc
              key = newKey
              break loopContinue
      else:
        discard

      # Recurse (iteratively)
      while true:
        block loopRecurse:
          # Modify last branch node and try again
          if result.path[^1].node.kind == Branch:
            for inx in result.path[^1].nibble+1 .. 15:
              let newKey = result.path[^1].node.bLink[inx]
              if 0 < newKey.len:
                value = newKey.getFn()
                if 0 < value.len:
                  result.path[^1].nibble = inx.int8
                  key = newKey
                  break loopContinue
          # Failed, step back and try predecessor branch.
          while path.path.len < result.path.len:
            case result.path[^1].node.kind:
            of Branch:
              result.depth.dec
              result.path.setLen(result.path.len - 1)
              break loopRecurse
            of Extension:
              result.depth -= result.path[^1].node.ePfx.len
              result.path.setLen(result.path.len - 1)
            of Leaf:
              return # Ooops
          return # Failed
      # Notreached
    # End while
  # Notreached


proc pathMost(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## For the partial path given, extend by branch nodes with greatest node
  ## indices.
  result = path
  result.tail = EmptyNibbleRange
  result.depth = result.getNibblesImpl.len

  var
    key = key
    value = key.getFn()
  if value.len == 0:
    return

  while true:
    block loopContinue:
      let nodeRlp = rlpFromBytes value
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes

        # Leaf node
        if isLeaf:
          let node = nodeRlp.toLeafNode(pathSegment)
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          result.depth += pathSegment.len
          return # done ok

        # Extension node
        let node = nodeRlp.toExtensionNode(pathSegment)
        if 0 < node.eLink.len:
          value = node.eLink.getFn()
          if 0 < value.len:
            result.path.add XPathStep(key: key, node: node, nibble: -1)
            result.depth += pathSegment.len
            key = node.eLink
            break loopContinue
      of 17:
        # Branch node
        let node = nodeRlp.toBranchNode
        if node.bLink[16].len != 0 and 64 <= result.depth:
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          return # done ok

        for inx in 15.countDown(0):
          let newKey = node.bLink[inx]
          if 0 < newKey.len:
            value = newKey.getFn()
            if 0 < value.len:
              result.path.add XPathStep(key: key, node: node, nibble: inx.int8)
              result.depth.inc
              key = newKey
              break loopContinue
      else:
        discard

      # Recurse (iteratively)
      while true:
        block loopRecurse:
          # Modify last branch node and try again
          if result.path[^1].node.kind == Branch:
            for inx in (result.path[^1].nibble-1).countDown(0):
              let newKey = result.path[^1].node.bLink[inx]
              if 0 < newKey.len:
                value = newKey.getFn()
                if 0 < value.len:
                  result.path[^1].nibble = inx.int8
                  key = newKey
                  break loopContinue
          # Failed, step back and try predecessor branch.
          while path.path.len < result.path.len:
            case result.path[^1].node.kind:
            of Branch:
              result.depth.dec
              result.path.setLen(result.path.len - 1)
              break loopRecurse
            of Extension:
              result.depth -= result.path[^1].node.ePfx.len
              result.path.setLen(result.path.len - 1)
            of Leaf:
              return # Ooops
          return # Failed
      # Notreached
    # End while
  # Notreached

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc getNibbles*(path: XPath; start = 0): NibblesSeq =
  ## Re-build the key path
  path.getNibblesImpl(start)

proc leafData*(path: XPath): Blob =
  ## Return the leaf data from a successful `XPath` computation (if any.)
  if path.tail.len == 0 and 0 < path.path.len:
    let node = path.path[^1].node
    case node.kind:
    of Branch:
      return node.bLink[16]
    of Leaf:
      return node.lData
    of Extension:
      discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryPath*(
    nodeKey: NodeKey;
    rootKey: RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Compute logest possible repair tree `db` path matching the `nodeKey`
  ## nibbles. The `nodeNey` path argument come first to support a more
  ## functional notation.
  RPath(tail: nodeKey.to(NibblesSeq)).pathExtend(rootKey,db)

proc hexaryPath*(
    partialPath: NibblesSeq;
    rootKey: RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Variant of `hexaryPath`.
  RPath(tail: partialPath).pathExtend(rootKey,db)

proc hexaryPath*(
    nodeKey: NodeKey;
    root: NodeKey;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Compute logest possible path on an arbitrary hexary trie. Note that this
  ## prototype resembles the other ones with the implict `state root`. The
  ## rules for the protopye arguments are:
  ## * First argument is the node key, the node path to be followed
  ## * Last argument is the database (needed only here for debugging)
  ##
  ## Note that this function will flag a potential lowest level `Extception`
  ## in the invoking function due to the `getFn` argument.
  XPath(tail: nodeKey.to(NibblesSeq)).pathExtend(root.to(Blob), getFn)

proc hexaryPath*(
    partialPath: NibblesSeq;
    root: NodeKey;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `hexaryPath`.
  XPath(tail: partialPath).pathExtend(root.to(Blob), getFn)

proc next*(
    path: XPath;
    getFn: HexaryGetFn;
    minDepth = 64;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Advance the argument `path` to the next leaf node (if any.). The
  ## `minDepth` argument requires the result of `next()` to satisfy
  ## `minDepth <= next().getNibbles.len`.
  var pLen = path.path.len

  # Find the last branch in the path, increase link and step down
  while 0 < pLen:

    # Find branch none
    pLen.dec

    let it = path.path[pLen]
    if it.node.kind == Branch and it.nibble < 15:

      # Find the next item to the right in the branch list
      for inx in (it.nibble + 1) .. 15:
        let link = it.node.bLink[inx]
        if link.len != 0:
          let
            branch = XPathStep(key: it.key, node: it.node, nibble: inx.int8)
            walk = path.path[0 ..< pLen] & branch
            newPath = XPath(path: walk).pathLeast(link, getFn)
          if minDepth <= newPath.depth and 0 < newPath.leafData.len:
            return newPath

proc prev*(
    path: XPath;
    getFn: HexaryGetFn;
    minDepth = 64;
      ): XPath
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Advance the argument `path` to the previous leaf node (if any.) The
  ## `minDepth` argument requires the result of `next()` to satisfy
  ## `minDepth <= next().getNibbles.len`.
  var pLen = path.path.len

  # Find the last branch in the path, decrease link and step down
  while 0 < pLen:

    # Find branch none
    pLen.dec
    let it = path.path[pLen]
    if it.node.kind == Branch and 0 < it.nibble:

      # Find the next item to the right in the branch list
      for inx in (it.nibble - 1).countDown(0):
        let link = it.node.bLink[inx]
        if link.len != 0:
          let
            branch = XPathStep(key: it.key, node: it.node, nibble: inx.int8)
            walk = path.path[0 ..< pLen] & branch
            newPath = XPath(path: walk).pathMost(link, getFn)
          if minDepth <= newPath.depth and 0 < newPath.leafData.len:
            return newPath

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
