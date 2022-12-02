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
  std/tables,
  eth/[common, trie/nibbles],
  stew/results,
  ./hexary_desc

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

proc completeLeast(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
    pathLenMax = 64;
      ): Result[RPath,void]
      {.gcsafe, raises: [Defect,KeyError].} =
  ## Extend path using least nodes without recursion.
  var rPath = RPath(path: path.path)
  if db.tab.hasKey(key):
    var
      key = key
      node = db.tab[key]

    while rPath.path.len < pathLenMax:
      case node.kind:
      of Leaf:
        rPath.path.add RPathStep(key: key, node: node, nibble: -1)
        return ok(rPath) # done

      of Extension:
        block useExtensionLink:
          let newKey = node.eLink
          if not newkey.isZero:
            if db.tab.hasKey(newKey):
              rPath.path.add RPathStep(key: key, node: node, nibble: -1)
              key = newKey
              node = db.tab[key]
              break useExtensionLink
          return err() # Oops, no way

      of Branch:
        block findBranchLink:
          for inx in 0 .. 15:
            let newKey = node.bLink[inx]
            if not newKey.isZero:
              if db.tab.hasKey(newKey):
                rPath.path.add RPathStep(key: key, node: node, nibble: inx.int8)
                key = newKey
                node = db.tab[key]
                break findBranchLink
          return err() # Oops, no way
  err()


proc completeLeast(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
    pathLenMax = 64;
      ): Result[XPath,void]
      {.gcsafe, raises: [Defect,RlpError].} =
  ## Variant of `completeLeast()` for persistent database
  var xPath = XPath(path: path.path)
  if 0 < key.getFn().len:
    var
      key = key
      nodeRlp = rlpFromBytes key.getFn()

    while xPath.path.len < pathLenMax:
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,pathSegment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        if isLeaf:
          let node = nodeRlp.toLeafNode(pathSegment)
          xPath.path.add XPathStep(key: key, node: node, nibble: -1)
          return ok(xPath) # done

        # Extension
        block useExtensionLink:
          let
            node = nodeRlp.toExtensionNode(pathSegment)
            newKey = node.eLink
          if 0 < newKey.len:
            let newNode = newKey.getFn()
            if 0 < newNode.len:
              xPath.path.add XPathStep(key: key, node: node, nibble: -1)
              key = newKey
              nodeRlp = rlpFromBytes newNode
              break useExtensionLink
          return err() # Oops, no way

      of 17:
        block findBranchLink:
          let node = nodeRlp.toBranchNode()
          for inx in 0 .. 15:
            let newKey = node.bLink[inx]
            if 0 < newKey.len:
              let newNode = newKey.getFn()
              if 0 < newNode.len:
                xPath.path.add XPathStep(key: key, node: node, nibble: inx.int8)
                key = newKey
                nodeRlp =  rlpFromBytes newNode
                break findBranchLink
          return err() # Oops, no way

      else:
        return err() # Oops, no way
  err()

# ------------------------------------------------------------------------------
# Public functions, verify boundary proofs
# ------------------------------------------------------------------------------

proc hexaryNearbyRight*(
    path: RPath;                   ## Partially expanded path
    db: HexaryTreeDbRef;           ## Database
      ): Result[RPath,void]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Extends the maximally extended argument nodes `path` to the right (i.e.
  ## with non-decreasing path value). This is similar to the
  ## `hexary_path.next()` function, only that this algorithm does not
  ## backtrack if there are dangling links in between and rather returns
  ## a error.
  ##
  ## This code is intended be used for verifying a left-bound proof to verify
  ## that there is no leaf node.

  # Some easy cases
  if path.path.len == 0:
    return err() # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var rPath = path
  while 0 < rPath.path.len:
    let top = rPath.path[^1]
    if top.node.kind != Branch or
       top.nibble < 0 or
       rPath.tail.len == 0:
      return err() # error

    let topLink = top.node.bLink[top.nibble]
    if topLink.isZero or not db.tab.hasKey(topLink):
      return err() # error

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

  err() # error


proc hexaryNearbyRight*(
    path: XPath;                   ## Partially expanded path
    getFn: HexaryGetFn;            ## Database abstraction
      ): Result[XPath,void]
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `right()` for persistant database

  # Some easy cases
  if path.path.len == 0:
    return err() # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var xPath = path
  while 0 < xPath.path.len:
    let top = xPath.path[^1]
    if top.node.kind != Branch or
       top.nibble < 0 or
       xPath.tail.len == 0:
      return err() # error

    let topLink = top.node.bLink[top.nibble]
    if topLink.len == 0 or topLink.getFn().len == 0:
      return err() # error

    let nextNibble = xPath.tail[0].int8
    if nextNibble < 15:
      let
        nextNodeRlp = rlpFromBytes topLink.getFn()
        xPathLen = xPath.path.len # in case of backtracking
      case nextNodeRlp.listLen:
      of 2:
        if xPath.tail <= nextNodeRlp.listElem(0).toBytes.hexPrefixDecode[1]:
          return xPath.completeLeast(topLink, getFn)
      of 17:
        # Step down and complete with a branch link on the child node
        xPath.path = xPath.path & XPathStep(
          key:    topLink,
          node:   nextNodeRlp.toBranchNode,
          nibble: nextNibble)
      else:
        return err() # error

      # Find the next item to the right of the new top entry
      let step = xPath.path[^1]
      for inx in (step.nibble + 1) .. 15:
        let link = step.node.bLink[inx]
        if 0 < link.len:
          xPath.path[^1].nibble = inx.int8
          return xPath.completeLeast(link, getFn)

      # Restore `xPath` and backtrack
      xPath.path.setLen(xPathLen)

    # Pop `Branch` node on top and append nibble to `tail`
    xPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & xPath.tail
    xPath.path.setLen(xPath.path.len - 1)

  # Pathological case: nfffff.. for n < f
  var step = path.path[0]
  for inx in (step.nibble + 1) .. 15:
    let link = step.node.bLink[inx]
    if 0 < link.len:
      step.nibble = inx.int8
      xPath.path = @[step]
      return xPath.completeLeast(link, getFn)

  err() # error


proc hexaryNearbyRightMissing*(
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
