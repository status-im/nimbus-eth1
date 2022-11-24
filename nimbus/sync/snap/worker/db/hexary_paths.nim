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
  std/[algorithm, sequtils, tables],
  eth/[common, trie/nibbles],
  stew/[byteutils, interval_set],
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

proc `==`(a, b: XNodeObj): bool =
  if a.kind == b.kind:
    case a.kind:
    of Leaf:
      return a.lPfx == b.lPfx and a.lData == b.lData
    of Extension:
      return a.ePfx == b.ePfx and a.eLink == b.eLink
    of Branch:
      return a.bLink == b.bLink

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


proc `<=`(a, b: NibblesSeq): bool =
  ## Compare nibbles, different lengths are padded to the right with zeros
  let abMin = min(a.len, b.len)
  for n in 0 ..< abMin:
    if a[n] < b[n]:
      return true
    if b[n] < a[n]:
      return false
    # otherwise a[n] == b[n]

  # Assuming zero for missing entries
  if b.len < a.len:
    for n in abMin + 1 ..< a.len:
      if 0 < a[n]:
        return false
  true

proc `<`(a, b: NibblesSeq): bool =
  not (b <= a)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc padPartialPath(pfx: NibblesSeq; dblNibble: byte): NodeKey =
  ## Extend (or cut) `partialPath` nibbles sequence and generate `NodeKey`
  # Pad with zeroes
  var padded: NibblesSeq

  let padLen = 64 - pfx.len
  if 0 <= padLen:
    padded = pfx & dblNibble.repeat(padlen div 2).initNibbleRange
    if (padLen and 1) == 1:
      padded = padded & @[dblNibble].initNibbleRange.slice(1)
  else:
    let nope = seq[byte].default.initNibbleRange
    padded = pfx.slice(0,63) & nope # nope forces re-alignment

  let bytes = padded.getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)


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


proc completeLeast(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
    pathLenMax = 64;
      ): RPath
      {.gcsafe, raises: [Defect,KeyError].} =
  ## Extend path using least nodes without recursion.
  result.path = path.path
  if db.tab.hasKey(key):
    var
      key = key
      node = db.tab[key]

    while result.path.len < pathLenMax:
      case node.kind:
      of Leaf:
        result.path.add RPathStep(key: key, node: node, nibble: -1)
        return # done

      of Extension:
        block useExtensionLink:
          let newKey = node.eLink
          if not newkey.isZero and db.tab.hasKey(newKey):
            result.path.add RPathStep(key: key, node: node, nibble: -1)
            key = newKey
            node = db.tab[key]
            break useExtensionLink
          return # Oops, no way

      of Branch:
        block findBranchLink:
          for inx in 0 .. 15:
            let newKey = node.bLink[inx]
            if not newkey.isZero and db.tab.hasKey(newKey):
              result.path.add RPathStep(key: key, node: node, nibble: inx.int8)
              key = newKey
              node = db.tab[key]
              break findBranchLink
          return # Oops, no way


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


proc dismantleLeft(envPt, ivPt: RPath|XPath): Result[seq[Blob],void] =
  ## Helper for `dismantle()` for handling left side of envelope
  #
  #      partialPath
  #         / \
  #        /   \
  #       /     \
  #      /       \
  #    envPt..              -- envelope of partial path
  #        |
  #      ivPt..             -- `iv`, not fully covering left of `env`
  #
  var collect: seq[Blob]
  block leftCurbEnvelope:
    for n in 0 ..< min(envPt.path.len, ivPt.path.len):
      if envPt.path[n] != ivPt.path[n]:
        #
        # At this point, the `node` entries of either `path[n]` step are
        # the same. This is so because the predecessor steps were the same
        # or were the `rootKey` in case n == 0.
        #
        # But then (`node` entries being equal) the only way for the
        # `path[n]` steps to differ is in the entry selector `nibble` for
        # a branch node.
        #
        for m in n ..< ivPt.path.len:
          let
            pfx = ivPt.getNibblesImpl(0,m) # common path segment
            top = ivPt.path[m].nibble      # need nibbles smaller than top
          #
          # Incidentally for a non-`Branch` node, the value `top` becomes
          # `-1` and the `for`- loop will be ignored (which is correct)
          for nibble in 0 ..< top:
            collect.add hexPrefixEncode(
              pfx & @[nibble.byte].initNibbleRange.slice(1), isLeaf=false)
        break leftCurbEnvelope
    #
    # Fringe case, e.g. when `partialPath` is an empty prefix (aka `@[0]`)
    # and the database has a single leaf node `(a,some-value)` where the
    # `rootKey` is the hash of this node. In that case, `pMin == 0` and
    # `pMax == high(NodeTag)` and `iv == [a,a]`.
    #
    return err()

  ok(collect)

proc dismantleRight(envPt, ivPt: RPath|XPath): Result[seq[Blob],void] =
  ## Helper for `dismantle()` for handling right side of envelope
  #
  #       partialPath
  #           / \
  #          /   \
  #         /     \
  #        /       \
  #           .. envPt     -- envelope of partial path
  #              |
  #          .. ivPt       -- `iv`, not fully covering right of `env`
  #
  var collect: seq[Blob]
  block rightCurbEnvelope:
    for n in 0 ..< min(envPt.path.len, ivPt.path.len):
      if envPt.path[n] != ivPt.path[n]:
        for m in n ..< ivPt.path.len:
          let
            pfx = ivPt.getNibblesImpl(0,m) # common path segment
            base = ivPt.path[m].nibble     # need nibbles greater/equal
          if 0 <= base:
            for nibble in base+1 .. 15:
              collect.add hexPrefixEncode(
                pfx & @[nibble.byte].initNibbleRange.slice(1), isLeaf=false)
        break rightCurbEnvelope
    return err()

  ok(collect)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc getNibbles*(path: XPath|RPath; start = 0): NibblesSeq =
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

proc pathEnvelope*(partialPath: Blob): NodeTagRange =
  ## Convert partial path to range of all keys starting with this
  ## partial path
  let pfx = (hexPrefixDecode partialPath)[1]
  NodeTagRange.new(
    pfx.padPartialPath(0).to(NodeTag),
    pfx.padPartialPath(255).to(NodeTag))

proc pathSortUniq*(
    partialPaths: openArray[Blob];
      ): seq[Blob]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Sort and simplify a list of partial paths by removoing nested entries.

  var tab: Table[NodeTag,(Blob,bool)]
  for w in partialPaths:
    let iv = w.pathEnvelope
    tab[iv.minPt] = (w,true)    # begin entry
    tab[iv.maxPt] = (@[],false) # end entry

  # When sorted, nested entries look like
  #
  # 123000000.. (w0, true)
  # 123400000.. (w1, true)
  # 1234fffff..  (, false)
  # 123ffffff..  (, false)
  # ...
  # 777000000.. (w2, true)
  #
  var level = 0
  for key in toSeq(tab.keys).sorted(cmp):
    let (w,begin) = tab[key]
    if begin:
      if level == 0:
        result.add w
      level.inc
    else:
      level.dec

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


proc right*(
    path: RPath;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Extends the maximally extended argument nodes `path` to the right (with
  ## path value not decreasing). This is similar to `next()`, only that the
  ## algorithm does not backtrack if there are dangling links in between.
  ##
  ## This code is intended be used for verifying a left-bound proof.

  # Some easy cases
  if path.path.len == 0:
    return RPath() # error
  if path.path[^1].node.kind == Leaf:
    return path

  var rPath = path
  while 0 < rPath.path.len:
    let top = rPath.path[^1]
    if top.node.kind != Branch or
       top.nibble < 0 or
       rPath.tail.len == 0:
      return RPath() # error

    let topLink = top.node.bLink[top.nibble]
    if topLink.isZero or not db.tab.hasKey(topLink):
      return RPath() # error

    let nextNibble = rPath.tail[0].int8
    if nextNibble < 15:
      let
        nextNode = db.tab[topLink]
        rPathLen = rPath.path.len # in case of backtracking
      case nextNode.kind
      of Leaf:
        if rPath.tail <= nextNode.lPfx:
          return rPath.completeLeast(topLink, db)
      of Extension:
        if rPath.tail <= nextNode.ePfx:
          return rPath.completeLeast(topLink, db)
      of Branch:
        # Step down and complete with a branch link on the child node
        rPath.path = rPath.path & RPathStep(
          key:    topLink,
          node:   nextNode,
          nibble: nextNibble)

      # Find the next item to the right of the new top entry
      let step = rPath.path[^1]
      for inx in (step.nibble + 1) .. 15:
        let link = step.node.bLink[inx]
        if not link.isZero:
          rPath.path[^1].nibble = inx.int8
          return rPath.completeLeast(link, db)

      # Restore `rPath` and backtrack
      rPath.path.setLen(rPathLen)

    # Pop `Branch` node on top and append nibble to `tail`
    rPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & rPath.tail
    rPath.path.setLen(rPath.path.len - 1)

  # Pathological case: nfffff.. for n < f
  var step = path.path[0]
  for inx in (step.nibble + 1) .. 15:
    let link = step.node.bLink[inx]
    if not link.isZero:
      step.nibble = inx.int8
      rPath.path = @[step]
      return rPath.completeLeast(link, db)

  RPath() # error


proc rightStop*(
    path: RPath;
    db: HexaryTreeDbRef;
      ): bool
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Returns `true` if the maximally extended argument nodes `path` is the
  ## rightmost on the hexary trie database. It verifies that there is no more
  ## leaf entry to the right of the argument `path`.
  ##
  ## This code is intended be used for verifying a left-bound proof.
  if 0 < path.path.len and 0 < path.tail.len:
    let top = path.path[^1]
    if top.node.kind == Branch and 0 <= top.nibble:

      let topLink = top.node.bLink[top.nibble]
      if not topLink.isZero and db.tab.hasKey(topLink):
        let
          nextNibble = path.tail[0]
          nextNode = db.tab[topLink]

        case nextNode.kind
        of Leaf:
          return nextNode.lPfx < path.tail

        of Extension:
          return nextNode.ePfx < path.tail

        of Branch:
          # Step down and verify that there is no branch link
          for inx in nextNibble .. 15:
            if not nextNode.bLink[inx].isZero:
              return false
          return true


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


proc dismantle*(
    partialPath: Blob;             ## Patrial path for existing node
    rootKey: NodeKey;              ## State root
    iv: NodeTagRange;              ## Proofed range of leaf paths
    db: HexaryTreeDbRef;           ## Database
      ): seq[Blob]
      {.gcsafe, raises: [Defect,RlpError,KeyError]} =
  ## Returns the list of partial paths which envelopes span the range of
  ## node paths one obtains by subtracting the argument range `iv` from the
  ## envelope of the argumenr `partialPath`.
  ##
  ## The following boundary conditions apply in order to get a useful result
  ## in a partially completed hexary trie database.
  ##
  ## * The argument `partialPath` refers to an existing node.
  ##
  ## * The argument `iv` contains a range of paths (e.g. account hash keys)
  ##   with the property that if there is no (leaf-) node for that path, then
  ##   no such node exists when the database is completed.
  ##
  ##   This condition is sort of rephrasing the boundary proof condition that
  ##   applies when downloading a range of accounts or storage slots from the
  ##   network via `snap/1` protocol. In fact the condition here is stricter
  ##   as it excludes sub-trie *holes* (see comment on `importAccounts()`.)
  ##
  # Chechk for the trivial case when the `partialPath` envelope and `iv` do
  # not overlap.
  let env = partialPath.pathEnvelope
  if iv.maxPt < env.minPt or env.maxPt < iv.minPt:
    return @[partialPath]

  # So ranges do overlap. The case that the `partialPath` envelope is fully
  # contained in `iv` results in `@[]` which is implicitely handled by
  # non-matching any of the cases, below.
  if env.minPt < iv.minPt:
    let
      envPt = env.minPt.to(NodeKey).hexaryPath(rootKey.to(RepairKey), db)
      ivPt = iv.minPt.to(NodeKey).hexaryPath(rootKey.to(RepairKey), db)
    when false: # or true:
      echo ">>> ",
         "\n    ",  envPt.pp(db),
         "\n   -----",
         "\n    ",  ivPt.pp(db)
    let rc = envPt.dismantleLeft ivPt
    if rc.isErr:
      return @[partialPath]
    result &= rc.value

  if iv.maxPt < env.maxPt:
    let
      envPt = env.maxPt.to(NodeKey).hexaryPath(rootKey.to(RepairKey), db)
      ivPt = iv.maxPt.to(NodeKey).hexaryPath(rootKey.to(RepairKey), db)
    when false: # or true:
      echo ">>> ",
        "\n    ", envPt.pp(db),
        "\n   -----",
        "\n    ", ivPt.pp(db)
    let rc = envPt.dismantleRight ivPt
    if rc.isErr:
      return @[partialPath]
    result &= rc.value

proc dismantle*(
    partialPath: Blob;             ## Patrial path for existing node
    rootKey: NodeKey;              ## State root
    iv: NodeTagRange;              ## Proofed range of leaf paths
    getFn: HexaryGetFn;            ## Database abstraction
      ): seq[Blob]
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `dismantle()` for persistent database.
  let env = partialPath.pathEnvelope
  if iv.maxPt < env.minPt or env.maxPt < iv.minPt:
    return @[partialPath]

  if env.minPt < iv.minPt:
    let rc = dismantleLeft(
      env.minPt.to(NodeKey).hexaryPath(rootKey, getFn),
      iv.minPt.to(NodeKey).hexaryPath(rootKey, getFn))
    if rc.isErr:
      return @[partialPath]
    result &= rc.value

  if iv.maxPt < env.maxPt:
    let rc = dismantleRight(
      env.maxPt.to(NodeKey).hexaryPath(rootKey, getFn),
      iv.maxPt.to(NodeKey).hexaryPath(rootKey, getFn))
    if rc.isErr:
      return @[partialPath]
    result &= rc.value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
