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
  std/tables,
  eth/[common, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_paths]

proc hexaryNearbyRight*(path: RPath; db: HexaryTreeDbRef;
    ): Result[RPath,HexaryError] {.gcsafe, raises: [KeyError]}

proc hexaryNearbyRight*(path: XPath; getFn: HexaryGetFn;
    ): Result[XPath,HexaryError] {.gcsafe, raises: [CatchableError]}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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


template noKeyErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Impossible KeyError (" & info & "): " & e.msg

template noRlpErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert "Impossible RlpError (" & info & "): " & e.msg

# ------------------------------------------------------------------------------
# Private functions, wrappers
# ------------------------------------------------------------------------------

proc hexaryNearbyRightImpl(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Wrapper
  let path = block:
    let rc = baseTag.hexaryPath(rootKey, db).hexaryNearbyRight(db)
    if rc.isErr:
      return err(rc.error)
    rc.value

  if 0 < path.path.len and path.path[^1].node.kind == Leaf:
    let nibbles = path.getNibbles
    if nibbles.len == 64:
      return ok(nibbles.getBytes.convertTo(NodeTag))

  err(NearbyLeafExpected)

proc hexaryNearbyLeftImpl(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Wrapper
  let path = block:
    let rc = baseTag.hexaryPath(rootKey, db).hexaryNearbyLeft(db)
    if rc.isErr:
      return err(rc.error)
    rc.value

  if 0 < path.path.len and path.path[^1].node.kind == Leaf:
    let nibbles = path.getNibbles
    if nibbles.len == 64:
      return ok(nibbles.getBytes.convertTo(NodeTag))

  err(NearbyLeafExpected)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc completeLeast(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
    pathLenMax = 64;
      ): Result[RPath,HexaryError]
      {.gcsafe, raises: [KeyError].} =
  ## Extend path using least nodes without recursion.
  var rPath = RPath(path: path.path)

  if not db.tab.hasKey(key):
    return err(NearbyDanglingLink)
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
        return err(NearbyExtensionError) # Oops, no way

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
        return err(NearbyBranchError) # Oops, no way

  err(NearbyNestingTooDeep)


proc completeLeast(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
    pathLenMax = 64;
      ): Result[XPath,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `completeLeast()` for persistent database
  var xPath = XPath(path: path.path)

  if key.getFn().len == 0:
    return err(NearbyDanglingLink)
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
        return err(NearbyExtensionError) # Oops, no way

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
        return err(NearbyBranchError) # Oops, no way

    else:
      return err(NearbyGarbledNode) # Oops, no way

  err(NearbyNestingTooDeep)


proc completeMost(
    path: RPath;
    key: RepairKey;
    db: HexaryTreeDbRef;
    pathLenMax = 64;
      ): Result[RPath,HexaryError]
      {.gcsafe, raises: [KeyError].} =
  ## Extend path using max nodes without recursion.
  var rPath = RPath(path: path.path)

  if not db.tab.hasKey(key):
    return err(NearbyDanglingLink)
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
            node = db.tab[newKey]
            break useExtensionLink
        return err(NearbyExtensionError) # Oops, no way

    of Branch:
      block findBranchLink:
        for inx in 15.countDown(0):
          let newKey = node.bLink[inx]
          if not newKey.isZero:
            if db.tab.hasKey(newKey):
              rPath.path.add RPathStep(key: key, node: node, nibble: inx.int8)
              key = newKey
              node = db.tab[key]
              break findBranchLink
        return err(NearbyBranchError) # Oops, no way

  err(NearbyNestingTooDeep)

proc completeMost(
    path: XPath;
    key: Blob;
    getFn: HexaryGetFn;
    pathLenMax = 64;
      ): Result[XPath,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `completeLeast()` for persistent database
  var xPath = XPath(path: path.path)

  if key.getFn().len == 0:
    return err(NearbyDanglingLink)
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
        return err(NearbyExtensionError) # Oops, no way

    of 17:
      block findBranchLink:
        let node = nodeRlp.toBranchNode()
        for inx in 15.countDown(0):
          let newKey = node.bLink[inx]
          if 0 < newKey.len:
            let newNode = newKey.getFn()
            if 0 < newNode.len:
              xPath.path.add XPathStep(key: key, node: node, nibble: inx.int8)
              key = newKey
              nodeRlp =  rlpFromBytes newNode
              break findBranchLink
        return err(NearbyBranchError) # Oops, no way

    else:
      return err(NearbyGarbledNode) # Oops, no way

  err(NearbyNestingTooDeep)

# ------------------------------------------------------------------------------
# Public functions, left boundary proofs (moving right)
# ------------------------------------------------------------------------------

proc hexaryNearbyRight*(
    path: RPath;                   # Partially expanded path
    db: HexaryTreeDbRef;           # Database
      ): Result[RPath,HexaryError]
      {.gcsafe, raises: [KeyError]} =
  ## Extends the maximally extended argument nodes `path` to the right (i.e.
  ## with non-decreasing path value). This is similar to the
  ## `hexary_path.next()` function, only that this algorithm does not
  ## backtrack if there are dangling links in between and rather returns
  ## an error.
  ##
  ## This code is intended to be used for verifying a left-bound proof to
  ## verify that there is no leaf node *right* of a boundary path value.

  # Some easy cases
  if path.path.len == 0:
    return err(NearbyEmptyPath) # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var
    rPath = path
    start = true
  while 0 < rPath.path.len:
    let top = rPath.path[^1]
    case top.node.kind:
    of Leaf:
      return err(NearbyUnexpectedNode)
    of Branch:
      if top.nibble < 0 or rPath.tail.len == 0:
        return err(NearbyUnexpectedNode)
    of Extension:
      rPath.tail = top.node.ePfx & rPath.tail
      rPath.path.setLen(rPath.path.len - 1)
      continue

    var
      step = top
    let
      rPathLen = rPath.path.len # in case of backtracking
      rPathTail = rPath.tail    # in case of backtracking

    # Look ahead checking next node
    if start:
      let topLink = top.node.bLink[top.nibble]
      if topLink.isZero or not db.tab.hasKey(topLink):
        return err(NearbyDanglingLink) # error

      let nextNode = db.tab[topLink]
      case nextNode.kind
      of Leaf:
        if rPath.tail <= nextNode.lPfx:
          return rPath.completeLeast(topLink, db)
      of Extension:
        if rPath.tail <= nextNode.ePfx:
          return rPath.completeLeast(topLink, db)
      of Branch:
        let nextNibble = rPath.tail[0].int8
        if start and nextNibble < 15:
          # Step down and complete with a branch link on the child node
          step = RPathStep(
            key:    topLink,
            node:   nextNode,
            nibble: nextNibble)
          rPath.path &= step

    # Find the next item to the right of the current top entry
    for inx in (step.nibble + 1) .. 15:
      let link = step.node.bLink[inx]
      if not link.isZero:
        rPath.path[^1].nibble = inx.int8
        return rPath.completeLeast(link, db)

    if start:
      # Retry without look ahead
      start = false

      # Restore `rPath` (pop temporary extra step)
      if rPathLen < rPath.path.len:
        rPath.path.setLen(rPathLen)
        rPath.tail = rPathTail
    else:
      # Pop current `Branch` node on top and append nibble to `tail`
      rPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & rPath.tail
      rPath.path.setLen(rPath.path.len - 1)
    # End while

  # Pathological case: nfffff.. for n < f
  var step = path.path[0]
  for inx in (step.nibble + 1) .. 15:
    let link = step.node.bLink[inx]
    if not link.isZero:
      step.nibble = inx.int8
      rPath.path = @[step]
      return rPath.completeLeast(link, db)

  err(NearbyFailed) # error

proc hexaryNearbyRight*(
    path: XPath;                   # Partially expanded path
    getFn: HexaryGetFn;            # Database abstraction
      ): Result[XPath,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryNearbyRight()` for persistant database

  # Some easy cases
  if path.path.len == 0:
    return err(NearbyEmptyPath) # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var
    xPath = path
    start = true
  while 0 < xPath.path.len:
    let top = xPath.path[^1]
    case top.node.kind:
    of Leaf:
      return err(NearbyUnexpectedNode)
    of Branch:
      if top.nibble < 0 or xPath.tail.len == 0:
        return err(NearbyUnexpectedNode)
    of Extension:
      xPath.tail = top.node.ePfx & xPath.tail
      xPath.path.setLen(xPath.path.len - 1)
      continue

    var
      step = top
    let
      xPathLen = xPath.path.len # in case of backtracking
      xPathTail = xPath.tail    # in case of backtracking

    # Look ahead checking next node
    if start:
      let topLink = top.node.bLink[top.nibble]
      if topLink.len == 0 or topLink.getFn().len == 0:
        return err(NearbyDanglingLink) # error

      let nextNodeRlp = rlpFromBytes topLink.getFn()
      case nextNodeRlp.listLen:
      of 2:
        if xPath.tail <= nextNodeRlp.listElem(0).toBytes.hexPrefixDecode[1]:
          return xPath.completeLeast(topLink, getFn)
      of 17:
        let nextNibble = xPath.tail[0].int8
        if nextNibble < 15:
          # Step down and complete with a branch link on the child node
          step = XPathStep(
            key:    topLink,
            node:   nextNodeRlp.toBranchNode,
            nibble: nextNibble)
          xPath.path &= step
      else:
        return err(NearbyGarbledNode) # error

    # Find the next item to the right of the current top entry
    for inx in (step.nibble + 1) .. 15:
      let link = step.node.bLink[inx]
      if 0 < link.len:
        xPath.path[^1].nibble = inx.int8
        return xPath.completeLeast(link, getFn)

    if start:
      # Retry without look ahead
      start = false

      # Restore `xPath` (pop temporary extra step)
      if xPathLen < xPath.path.len:
        xPath.path.setLen(xPathLen)
        xPath.tail = xPathTail
    else:
      # Pop current `Branch` node on top and append nibble to `tail`
      xPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & xPath.tail
      xPath.path.setLen(xPath.path.len - 1)
    # End while

  # Pathological case: nfffff.. for n < f
  var step = path.path[0]
  for inx in (step.nibble + 1) .. 15:
    let link = step.node.bLink[inx]
    if 0 < link.len:
      step.nibble = inx.int8
      xPath.path = @[step]
      return xPath.completeLeast(link, getFn)

  err(NearbyFailed) # error


proc hexaryNearbyRightMissing*(
    path: RPath;
    db: HexaryTreeDbRef;
      ): bool
      {.gcsafe, raises: [KeyError]} =
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
# Public functions, right boundary proofs (moving left)
# ------------------------------------------------------------------------------

proc hexaryNearbyLeft*(
    path: RPath;                   # Partially expanded path
    db: HexaryTreeDbRef;           # Database
      ): Result[RPath,HexaryError]
      {.gcsafe, raises: [KeyError]} =
  ## Similar to `hexaryNearbyRight()`.
  ##
  ## This code is intended to be used for verifying a right-bound proof to
  ## verify that there is no leaf node *left* to a boundary path value.

  # Some easy cases
  if path.path.len == 0:
    return err(NearbyEmptyPath) # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var
    rPath = path
    start = true
  while 0 < rPath.path.len:
    let top = rPath.path[^1]
    case top.node.kind:
    of Leaf:
      return err(NearbyUnexpectedNode)
    of Branch:
      if top.nibble < 0 or rPath.tail.len == 0:
        return err(NearbyUnexpectedNode)
    of Extension:
      rPath.tail = top.node.ePfx & rPath.tail
      rPath.path.setLen(rPath.path.len - 1)
      continue

    var
      step = top
    let
      rPathLen = rPath.path.len # in case of backtracking
      rPathTail = rPath.tail    # in case of backtracking

    # Look ahead checking next node
    if start:
      let topLink = top.node.bLink[top.nibble]
      if topLink.isZero or not db.tab.hasKey(topLink):
        return err(NearbyDanglingLink) # error

      let nextNode = db.tab[topLink]
      case nextNode.kind
      of Leaf:
        if nextNode.lPfx <= rPath.tail:
          return rPath.completeMost(topLink, db)
      of Extension:
        if nextNode.ePfx <= rPath.tail:
          return rPath.completeMost(topLink, db)
      of Branch:
        let nextNibble = rPath.tail[0].int8
        if 0 < nextNibble:
          # Step down and complete with a branch link on the child node
          step = RPathStep(
            key:    topLink,
            node:   nextNode,
            nibble: nextNibble)
          rPath.path &= step

    # Find the next item to the right of the new top entry
    for inx in (step.nibble - 1).countDown(0):
      let link = step.node.bLink[inx]
      if not link.isZero:
        rPath.path[^1].nibble = inx.int8
        return rPath.completeMost(link, db)

    if start:
      # Retry without look ahead
      start = false

      # Restore `rPath` (pop temporary extra step)
      if rPathLen < rPath.path.len:
        rPath.path.setLen(rPathLen)
        rPath.tail = rPathTail
    else:
      # Pop current `Branch` node on top and append nibble to `tail`
      rPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & rPath.tail
      rPath.path.setLen(rPath.path.len - 1)
    # End while

  # Pathological case: n0000.. for 0 < n
  var step = path.path[0]
  for inx in (step.nibble - 1).countDown(0):
    let link = step.node.bLink[inx]
    if not link.isZero:
      step.nibble = inx.int8
      rPath.path = @[step]
      return rPath.completeMost(link, db)

  err(NearbyFailed) # error


proc hexaryNearbyLeft*(
    path: XPath;                   # Partially expanded path
    getFn: HexaryGetFn;            # Database abstraction
      ): Result[XPath,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryNearbyLeft()` for persistant database

  # Some easy cases
  if path.path.len == 0:
    return err(NearbyEmptyPath) # error
  if path.path[^1].node.kind == Leaf:
    return ok(path)

  var
    xPath = path
    start = true
  while 0 < xPath.path.len:
    let top = xPath.path[^1]
    case top.node.kind:
    of Leaf:
      return err(NearbyUnexpectedNode)
    of Branch:
      if top.nibble < 0 or xPath.tail.len == 0:
        return err(NearbyUnexpectedNode)
    of Extension:
      xPath.tail = top.node.ePfx & xPath.tail
      xPath.path.setLen(xPath.path.len - 1)
      continue

    var
      step = top
    let
      xPathLen = xPath.path.len # in case of backtracking
      xPathTail = xPath.tail    # in case of backtracking

    # Look ahead checking next node
    if start:
      let topLink = top.node.bLink[top.nibble]
      if topLink.len == 0 or topLink.getFn().len == 0:
        return err(NearbyDanglingLink) # error

      let nextNodeRlp = rlpFromBytes topLink.getFn()
      case nextNodeRlp.listLen:
      of 2:
        if nextNodeRlp.listElem(0).toBytes.hexPrefixDecode[1] <= xPath.tail:
          return xPath.completeMost(topLink, getFn)
      of 17:
        let nextNibble = xPath.tail[0].int8
        if 0 < nextNibble:
          # Step down and complete with a branch link on the child node
          step = XPathStep(
            key:    topLink,
            node:   nextNodeRlp.toBranchNode,
            nibble: nextNibble)
          xPath.path &= step
      else:
        return err(NearbyGarbledNode) # error

    # Find the next item to the right of the new top entry
    for inx in (step.nibble - 1).countDown(0):
      let link = step.node.bLink[inx]
      if 0 < link.len:
        xPath.path[^1].nibble = inx.int8
        return xPath.completeMost(link, getFn)

    if start:
      # Retry without look ahead
      start = false

      # Restore `xPath` (pop temporary extra step)
      if xPathLen < xPath.path.len:
        xPath.path.setLen(xPathLen)
        xPath.tail = xPathTail
    else:
      # Pop `Branch` node on top and append nibble to `tail`
      xPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & xPath.tail
      xPath.path.setLen(xPath.path.len - 1)
    # End while

  # Pathological case: n00000.. for 0 < n
  var step = path.path[0]
  for inx in (step.nibble - 1).countDown(0):
    let link = step.node.bLink[inx]
    if 0 < link.len:
      step.nibble = inx.int8
      xPath.path = @[step]
      return xPath.completeMost(link, getFn)

  err(NearbyFailed) # error

# ------------------------------------------------------------------------------
# Public functions, convenience wrappers
# ------------------------------------------------------------------------------

proc hexaryNearbyRight*(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryNearbyRight()` working with `NodeTag` arguments rather
  ## than `RPath` or `XPath` ones.
  noRlpErrorOops("hexaryNearbyRight"):
    return baseTag.hexaryNearbyRightImpl(rootKey, db)


proc hexaryNearbyLeft*(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## Similar to `hexaryNearbyRight()` for `NodeKey` arguments.
  noRlpErrorOops("hexaryNearbyLeft"):
    return baseTag.hexaryNearbyLeftImpl(rootKey, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
