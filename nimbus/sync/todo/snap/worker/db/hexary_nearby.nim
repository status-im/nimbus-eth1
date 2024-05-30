# nimbus-eth1
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
  results,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_nodes_helper, hexary_paths]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

proc complete(
    path: RPath|XPath;                  # Partially expanded path
    key: RepairKey|NodeKey|Blob;        # Start key
    db: HexaryTreeDbRef|HexaryGetFn;    # Database abstraction
    pathLenMax: int;                    # Beware of loops (if any)
    doLeast: static[bool];              # Direction: *least* or *most*
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## Extend path using least or last nodes without recursion.
  var uPath = typeof(path)(root: path.root, path: path.path)

  let firstNode = key.getNode(db)
  if firstNode.isErr:
    return Result[typeof(path),HexaryError].err(firstNode.error)
  var
    key = key
    node = firstNode.value

  while uPath.path.len < pathLenMax:
    case node.kind:
    of Leaf:
      uPath.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
      return ok(uPath) # done

    of Extension:
      let newKey = node.eLink
      if not newKey.isZeroLink:
        let newNode = newKey.getNode(db)
        if newNode.isOK:
          uPath.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
          key = newKey
          node = newNode.value
          continue
      return err(NearbyExtensionError) # Oops, no way

    of Branch:
      let n = block:
        when doLeast:
          node.branchNibbleMin 0
        else:
          node.branchNibbleMax 15
      if 0 <= n:
        let
          newKey = node.bLink[n]
          newNode = newKey.getNode(db)
        if newNode.isOK:
          uPath.path.add typeof(path.path[0])(key: key, node: node, nibble: n)
          key = newKey
          node = newNode.value
          continue
      return err(NearbyBranchError) # Oops, no way

  err(NearbyNestingTooDeep)


proc zeroAdjust(
   path: XPath|RPath;                 # Partially expanded path
   db: HexaryTreeDbRef|HexaryGetFn;   # Database abstraction
   doLeast: static[bool];             # Direction: *least* or *most*
     ): auto
     {.gcsafe, raises: [CatchableError].} =
  ## Adjust empty argument path to the first node entry to the right. Ths
  ## applies is the argument path `path` is before the first entry in the
  ## database. The result is a path which is aligned with the first entry.
  proc accept(p: typeof(path); pfx: NibblesSeq): bool =
    when doLeast:
      p.tail <= pfx
    else:
      pfx <= p.tail

  proc branchBorderNibble(w: typeof(path.path[0].node); n: int8): int8 =
    when doLeast:
      w.branchNibbleMin n
    else:
      w.branchNibbleMax n

  if path.path.len != 0:
    return Result[typeof(path),HexaryError].ok(path)

  let root = path.root.getNode(db)
  if root.isOk:
    block fail:
      var pfx: NibblesSeq
      case root.value.kind:
      of Branch:
        # Find first non-dangling link and assign it
        if path.tail.len == 0:
          break fail
        let n = root.value.branchBorderNibble path.tail[0].int8
        if n < 0:
          # Before or after the database range
          return err(NearbyBeyondRange)
        pfx = @[n.byte].initNibbleRange.slice(1)

      of Extension:
        let ePfx = root.value.ePfx
        # Must be followed by a branch node
        if path.tail.len < 2 or not path.accept(ePfx):
          break fail
        let node = root.value.eLink.getNode(db)
        if node.isErr:
          break fail
        let n = node.value.branchBorderNibble path.tail[1].int8
        if n < 0:
          # Before or after the database range
          return err(NearbyBeyondRange)
        pfx = ePfx & @[n.byte].initNibbleRange.slice(1)

      of Leaf:
        pfx = root.value.lPfx
        if not path.accept(pfx):
          # Before or after the database range
          return err(NearbyBeyondRange)

      let newPath = pfx.padPartialPath(0).hexaryPath(path.root, db)
      if 0 < newPath.path.len:
        return ok(newPath)

  err(NearbyEmptyPath)


proc finalise(
    path: XPath|RPath;               # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn; # Database abstraction
    moveRight: static[bool];         # Direction of next node
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## Handle some pathological cases after main processing failed
  proc beyond(p: typeof(path); pfx: NibblesSeq): bool =
    when moveRight:
      pfx < p.tail
    else:
      p.tail < pfx

  proc branchBorderNibble(w: typeof(path.path[0].node)): int8 =
    when moveRight:
      w.branchNibbleMax 15
    else:
      w.branchNibbleMin 0

  # Just for completeness (this case should have been handled, already)
  if path.path.len == 0:
    return Result[typeof(path),HexaryError].err(NearbyEmptyPath)

  # Check whether the path is beyond the database range
  if 0 < path.tail.len:         # nothing to compare against, otherwise
    let top = path.path[^1]
    # Note that only a `Branch` nodes has a non-zero nibble
    if 0 <= top.nibble and top.nibble == top.node.branchBorderNibble:
      # Check the following up node
      let rc = top.node.bLink[top.nibble].getNode(db)
      if rc.isErr:
        return err(NearbyDanglingLink)
      var pfx: NibblesSeq
      case rc.value.kind:
      of Leaf:
        pfx = rc.value.lPfx
      of Extension:
        pfx = rc.value.ePfx
      of Branch:
        pfx = @[rc.value.branchBorderNibble.byte].initNibbleRange.slice(1)
      if path.beyond pfx:
        return err(NearbyBeyondRange)

  # Pathological cases
  # * finalise right: nfffff.. for n < f or
  # * finalise left: n00000.. for 0 < n
  if path.path[0].node.kind == Branch or
     (1 < path.path.len and path.path[1].node.kind == Branch):
    return err(NearbyFailed) # no more nodes

  err(NearbyUnexpectedNode) # error


proc nearbyNext(
    path: RPath|XPath;               # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn; # Database abstraction
    moveRight: static[bool];         # Direction of next node
    pathLenMax = 64;                 # Beware of loops (if any)
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## Unified implementation of `hexaryNearbyRight()` and `hexaryNearbyLeft()`.
  proc accept(nibble: int8): bool =
    ## Accept `nibble` unless on boundaty dependent on `moveRight`
    when moveRight:
      nibble < 15
    else:
      0 < nibble

  proc accept(p: typeof(path); pfx: NibblesSeq): bool =
    when moveRight:
      p.tail <= pfx
    else:
      pfx <= p.tail

  proc branchNibbleNext(w: typeof(path.path[0].node); n: int8): int8 =
    when moveRight:
      w.branchNibbleMin(n + 1)
    else:
      w.branchNibbleMax(n - 1)

  # Some easy cases
  var path = block:
    let rc = path.zeroAdjust(db, doLeast=moveRight)
    if rc.isErr:
      return Result[typeof(path),HexaryError].err(rc.error)
    rc.value

  var
    uPath = path
    start = true
  while 0 < uPath.path.len:
    let top = uPath.path[^1]
    case top.node.kind:
    of Leaf:
      return ok(uPath)
    of Branch:
      if top.nibble < 0 or uPath.tail.len == 0:
        return err(NearbyUnexpectedNode)
    of Extension:
      uPath.tail = top.node.ePfx & uPath.tail
      uPath.path.setLen(uPath.path.len - 1)
      continue

    var
      step = top
    let
      uPathLen = uPath.path.len # in case of backtracking
      uPathTail = uPath.tail    # in case of backtracking

    # Look ahead checking next node
    if start:
      let
        topLink = top.node.bLink[top.nibble]
        nextNode = block:
          if topLink.isZeroLink:
            return err(NearbyDanglingLink) # error
          let rc = topLink.getNode(db)
          if rc.isErr:
            return err(rc.error) # error
          rc.value

      case nextNode.kind
      of Leaf:
        if uPath.accept(nextNode.lPfx):
          return uPath.complete(topLink, db, pathLenMax, doLeast=moveRight)
      of Extension:
        if uPath.accept(nextNode.ePfx):
          return uPath.complete(topLink, db, pathLenMax, doLeast=moveRight)
      of Branch:
        let nextNibble = uPath.tail[0].int8
        if start and accept(nextNibble):
          # Step down and complete with a branch link on the child node
          step = typeof(path.path[0])(
            key:    topLink,
            node:   nextNode,
            nibble: nextNibble)
          uPath.path &= step

    # Find the next item to the right/left of the current top entry
    let n = step.node.branchNibbleNext step.nibble
    if 0 <= n:
      uPath.path[^1].nibble = n
      return uPath.complete(
        step.node.bLink[n], db, pathLenMax, doLeast=moveRight)

    if start:
      # Retry without look ahead
      start = false

      # Restore `uPath` (pop temporary extra step)
      if uPathLen < uPath.path.len:
        uPath.path.setLen(uPathLen)
        uPath.tail = uPathTail
    else:
      # Pop current `Branch` node on top and append nibble to `tail`
      uPath.tail = @[top.nibble.byte].initNibbleRange.slice(1) & uPath.tail
      uPath.path.setLen(uPath.path.len - 1)
    # End while

  # Handle some pathological cases
  return path.finalise(db, moveRight)


proc nearbyNext(
    baseTag: NodeTag;                # Some node
    rootKey: NodeKey;                # State root
    db: HexaryTreeDbRef|HexaryGetFn; # Database abstraction
    moveRight: static[bool];         # Direction of next node
    pathLenMax = 64;                 # Beware of loops (if any)
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `nearbyNext()`, convenience wrapper
  let rc = baseTag.hexaryPath(rootKey, db).nearbyNext(db, moveRight)
  if rc.isErr:
    return err(rc.error)

  let path = rc.value
  if 0 < path.path.len and path.path[^1].node.kind == Leaf:
    let nibbles = path.getNibbles
    if nibbles.len == 64:
      return ok(nibbles.getBytes.convertTo(NodeTag))

  err(NearbyLeafExpected)

# ------------------------------------------------------------------------------
# Public functions, moving and right boundary proof
# ------------------------------------------------------------------------------

proc hexaryNearbyRight*(
    path: RPath|XPath;               # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn; # Database abstraction
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## Extends the maximally extended argument nodes `path` to the right (i.e.
  ## with non-decreasing path value). This is similar to the
  ## `hexary_path.next()` function, only that this algorithm does not
  ## backtrack if there are dangling links in between and rather returns
  ## an error.
  ##
  ## In the case that there is no more leaf node to the right of the argument
  ## path, the particular error code `NearbyBeyondRange` is returned.
  ##
  ## This code is intended to be used for verifying a left-bound proof to
  ## verify that there is no leaf node *right* of a boundary path value.
  path.nearbyNext(db, moveRight=true)

proc hexaryNearbyRight*(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `hexaryNearbyRight()` working with `NodeTag` arguments rather
  ## than `RPath` or `XPath` ones.
  baseTag.nearbyNext(rootKey, db, moveRight=true)

proc hexaryNearbyLeft*(
    path: RPath|XPath;               # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn; # Database abstraction
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## Similar to `hexaryNearbyRight()`.
  ##
  ## This code is intended to be used for verifying a right-bound proof to
  ## verify that there is no leaf node *left* to a boundary path value.
  path.nearbyNext(db, moveRight=false)

proc hexaryNearbyLeft*(
    baseTag: NodeTag;                 # Some node
    rootKey: NodeKey;                 # State root
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[NodeTag,HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Similar to `hexaryNearbyRight()` for `NodeKey` arguments.
  baseTag.nearbyNext(rootKey, db, moveRight=false)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc hexaryNearbyRightMissing*(
    path: RPath|XPath;                # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn;  # Database abstraction
      ): Result[bool,HexaryError]
      {.gcsafe, raises: [KeyError].} =
  ## Returns `true` if the maximally extended argument nodes `path` is the
  ## rightmost on the hexary trie database. It verifies that there is no more
  ## leaf entry to the right of the argument `path`. This function is an
  ## an alternative to
  ## ::
  ##   let rc = path.hexaryNearbyRight(db)
  ##   if rc.isOk:
  ##     # not at the end => false
  ##     ...
  ##   elif rc.error != NearbyBeyondRange:
  ##     # problem with database => error
  ##     ...
  ##   else:
  ##     # no nore nodes => true
  ##     ...
  ## and is intended mainly for debugging.
  if path.path.len == 0:
    return err(NearbyEmptyPath)
  if 0 < path.tail.len:
    return err(NearbyPathTail)

  let top = path.path[^1]
  if top.node.kind != Branch or top.nibble < 0:
    return err(NearbyBranchError)

  let nextNode = block:
    let topLink = top.node.bLink[top.nibble]
    if topLink.isZeroLink:
      return err(NearbyDanglingLink) # error
    let rc = topLink.getNode(db)
    if rc.isErr:
      return err(rc.error) # error
    rc.value

  case nextNode.kind
  of Leaf:
    return ok(nextNode.lPfx < path.tail)
  of Extension:
    return ok(nextNode.ePfx < path.tail)
  of Branch:
    return ok(nextNode.branchNibbleMin(path.tail[0].int8) < 0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
