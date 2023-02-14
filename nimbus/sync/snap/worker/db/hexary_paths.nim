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

{.push raises: [].}

import
  std/[sequtils, sets, tables],
  eth/[common, trie/nibbles],
  stew/[byteutils, interval_set],
  ../../range_desc,
  ./hexary_desc

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

#proc pp(w: Blob; db: HexaryTreeDbRef): string =
#  w.convertTo(RepairKey).pp(db)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(a: RepairKey; T: type RepairKey): RepairKey =
  ## Needed for generic function
  a

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc getNibblesImpl(path: XPath|RPath; start = 0): NibblesSeq =
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

proc getNibblesImpl(path: XPath|RPath; start, maxLen: int): NibblesSeq =
  ## Variant of `getNibblesImpl()` for partial rebuild
  for n in start ..< min(path.path.len, maxLen):
    let it = path.path[n]
    case it.node.kind:
    of Branch:
      result = result & @[it.nibble.byte].initNibbleRange.slice(1)
    of Extension:
      result = result & it.node.ePfx
    of Leaf:
      result = result & it.node.lPfx


proc toBranchNode(
    rlp: Rlp
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  var rlp = rlp
  XNodeObj(kind: Branch, bLink: rlp.read(array[17,Blob]))

proc toLeafNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  XNodeObj(kind: Leaf, lPfx: pSegm, lData: rlp.listElem(1).toBytes)

proc toExtensionNode(
    rlp: Rlp;
    pSegm: NibblesSeq
      ): XNodeObj
      {.gcsafe, raises: [RlpError]} =
  XNodeObj(kind: Extension, ePfx: pSegm, eLink: rlp.listElem(1).toBytes)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc pathExtend(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [KeyError].} =
  ## For the given path, extend to the longest possible repair tree `db`
  ## path following the argument `path.tail`.
  result = path
  var key = key
  while db.tab.hasKey(key):
    let node = db.tab[key]

    case node.kind:
    of Leaf:
      if result.tail.len == result.tail.sharedPrefixLen(node.lPfx):
        # Bingo, got full path
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        result.tail = EmptyNibbleRange
      return
    of Branch:
      if result.tail.len == 0:
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        return
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
      {.gcsafe, raises: [CatchableError]} =
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

      # Leaf node
      if isLeaf:
        if result.tail.len == nSharedNibbles:
          # Bingo, got full path
          let node = nodeRlp.toLeafNode(pathSegment)
          result.path.add XPathStep(key: key, node: node, nibble: -1)
          result.tail = EmptyNibbleRange
        return

      # Extension node
      if fullPath:
        let node = nodeRlp.toExtensionNode(pathSegment)
        if node.eLink.len == 0:
          return
        result.path.add XPathStep(key: key, node: node, nibble: -1)
        result.tail = result.tail.slice(nSharedNibbles)
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
      {.gcsafe, raises: [CatchableError]} =
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
      {.gcsafe, raises: [CatchableError]} =
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

proc getNibbles*(path: XPath|RPath; start = 0): NibblesSeq =
  ## Re-build the key path
  path.getNibblesImpl(start)

proc getNibbles*(path: XPath|RPath; start, maxLen: int): NibblesSeq =
  ## Variant of `getNibbles()`
  path.getNibblesImpl(start, maxLen)


proc getPartialPath*(path: XPath|RPath): Blob =
  ## Convert to hex encoded partial path as used in `eth` or `snap` protocol
  ## where full leaf paths of nibble length 64 are encoded as 32 byte `Blob`
  ## and non-leaf partial paths are *compact encoded* (i.e. per the Ethereum
  ## wire protocol.)
  let
    isLeaf = (0 < path.path.len and path.path[^1].node.kind == Leaf)
    nibbles = path.getNibbles
  if isLeaf and nibbles.len == 64:
    nibbles.getBytes
  else:
    nibbles.hexPrefixEncode(isLeaf)


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

proc leafData*(path: RPath): Blob =
  ## Return the leaf data from a successful `RPath` computation (if any.)
  if path.tail.len == 0 and 0 < path.path.len:
    let node = path.path[^1].node
    case node.kind:
    of Branch:
      return node.bData
    of Leaf:
      return node.lData
    of Extension:
      discard

# ------------------------------------------------------------------------------
# Public functions, hexary path constructors
# ------------------------------------------------------------------------------

proc hexaryPath*(
    partialPath: NibblesSeq;        # partial path to resolve
    rootKey: NodeKey|RepairKey;     # State root
    db: HexaryTreeDbRef;            # Database
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Compute the longest possible repair tree `db` path matching the `nodeKey`
  ## nibbles. The `nodeNey` path argument comes before the `db` one for
  ## supporting a more functional notation.
  RPath(tail: partialPath).pathExtend(rootKey.to(RepairKey), db)

proc hexaryPath*(
    nodeKey: NodeKey;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Variant of `hexaryPath` for a node key.
  nodeKey.to(NibblesSeq).hexaryPath(rootKey, db)

proc hexaryPath*(
    nodeTag: NodeTag;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Variant of `hexaryPath` for a node tag.
  nodeTag.to(NodeKey).hexaryPath(rootKey, db)

proc hexaryPath*(
    partialPath: Blob;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Variant of `hexaryPath` for a  hex encoded partial path.
  partialPath.hexPrefixDecode[1].hexaryPath(rootKey, db)


proc hexaryPath*(
    partialPath: NibblesSeq;        # partial path to resolve
    rootKey: NodeKey;               # State root
    getFn: HexaryGetFn;             # Database abstraction
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
  ## Compute the longest possible path on an arbitrary hexary trie.
  XPath(tail: partialPath).pathExtend(rootKey.to(Blob), getFn)

proc hexaryPath*(
    nodeKey: NodeKey;
    rootKey: NodeKey;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a node key..
  nodeKey.to(NibblesSeq).hexaryPath(rootKey, getFn)

proc hexaryPath*(
    nodeTag: NodeTag;
    rootKey: NodeKey;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a node tag..
  nodeTag.to(NodeKey).hexaryPath(rootKey, getFn)

proc hexaryPath*(
    partialPath: Blob;
    rootKey: NodeKey;
    getFn: HexaryGetFn;
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a hex encoded partial path.
  partialPath.hexPrefixDecode[1].hexaryPath(rootKey, getFn)

# ------------------------------------------------------------------------------
# Public helpers, partial paths resolvers
# ------------------------------------------------------------------------------

proc hexaryPathNodeKey*(
    partialPath: NibblesSeq;       # Hex encoded partial path
    rootKey: NodeKey|RepairKey;    # State root
    db: HexaryTreeDbRef;           # Database
    missingOk = false;             # Also return key for missing node
      ): Result[NodeKey,void]
      {.gcsafe, raises: [KeyError]} =
  ## Returns the `NodeKey` equivalent for the argment `partialPath` if this
  ## node is available in the database. If the argument flag `missingOk` is
  ## set`true` and the last node addressed by the argument path is missing,
  ## its key is returned as well.
  let steps = partialPath.hexaryPath(rootKey, db)
  if 0 < steps.path.len and steps.tail.len == 0:
    let top = steps.path[^1]
    # If the path was fully exhaused and the node exists for a `Branch` node,
    # then the `nibble` is `-1`.
    if top.nibble < 0 and top.key.isNodeKey:
      return ok(top.key.convertTo(NodeKey))
    if missingOk:
      let link = top.node.bLink[top.nibble]
      if not link.isZero and link.isNodeKey:
        return ok(link.convertTo(NodeKey))
  err()

proc hexaryPathNodeKey*(
    partialPath: Blob;             # Hex encoded partial path
    rootKey: NodeKey|RepairKey;    # State root
    db: HexaryTreeDbRef;           # Database
    missingOk = false;             # Also return key for missing node
      ): Result[NodeKey,void]
      {.gcsafe, raises: [KeyError]} =
  ## Variant of `hexaryPathNodeKey()` for hex encoded partial path.
  partialPath.hexPrefixDecode[1].hexaryPathNodeKey(rootKey, db, missingOk)


proc hexaryPathNodeKey*(
    partialPath: NibblesSeq;       # Hex encoded partial path
    rootKey: NodeKey;              # State root
    getFn: HexaryGetFn;            # Database abstraction
    missingOk = false;             # Also return key for missing node
      ): Result[NodeKey,void]
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPathNodeKey()` for persistent database.
  let steps = partialPath.hexaryPath(rootKey, getFn)
  if 0 < steps.path.len and steps.tail.len == 0:
    let top = steps.path[^1]
    # If the path was fully exhaused and the node exists for a `Branch` node,
    # then the `nibble` is `-1`.
    if top.nibble < 0:
      return ok(top.key.convertTo(NodeKey))
    if missingOk:
      let link = top.node.bLink[top.nibble]
      if 0 < link.len:
        return ok(link.convertTo(NodeKey))
  err()

proc hexaryPathNodeKey*(
    partialPath: Blob;             # Partial database path
    rootKey: NodeKey;              # State root
    getFn: HexaryGetFn;            # Database abstraction
    missingOk = false;             # Also return key for missing node
      ): Result[NodeKey,void]
     {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPathNodeKey()` for persistent database and
  ## hex encoded partial path.
  partialPath.hexPrefixDecode[1].hexaryPathNodeKey(rootKey, getFn, missingOk)

proc hexaryPathNodeKeys*(
    partialPaths: seq[Blob];       # Partial paths segments
    rootKey: NodeKey|RepairKey;    # State root
    db: HexaryTreeDbRef;           # Database
    missingOk = false;             # Also return key for missing node
      ): HashSet[NodeKey]
      {.gcsafe, raises: [KeyError]} =
  ## Convert a list of path segments to a set of node keys
  partialPaths.toSeq
    .mapIt(it.hexaryPathNodeKey(rootKey, db, missingOk))
    .filterIt(it.isOk)
    .mapIt(it.value)
    .toHashSet

# ------------------------------------------------------------------------------
# Public functions, traversal
# ------------------------------------------------------------------------------

proc next*(
    path: XPath;
    getFn: HexaryGetFn;
    minDepth = 64;
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
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
      {.gcsafe, raises: [CatchableError]} =
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
