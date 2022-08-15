# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## For a given path, sdd missing nodes to a hexary trie.
##
## This module function is temporary and proof-of-concept. for production
## purposes, it should be replaced by the new facility of the upcoming
## re-factored database layer.

import
  std/[sequtils, strformat, strutils, tables],
  eth/[common/eth_types, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_defs, hexary_desc]

{.push raises: [Defect].}

const
  RepairTreeDebugging = false

  EmptyNibbleRange = EmptyNodeBlob.initNibbleRange

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops (" & info & ") " & $e.name & ": " & e.msg

proc pp(w: RPathStep; db: HexaryTreeDB): string =
  noPpError("pp(RPathStep)])"):
    let nibble = if 0 <= w.nibble: &"{w.nibble:x}" else: "ø"
    result = &"({w.key.pp(db)},{nibble},{w.node.pp(db)})"

proc pp(w: openArray[RPathStep]; db: HexaryTreeDB; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(seq[RPathStep])"):
    result = w.toSeq.mapIt(it.pp(db)).join(pfx)

proc pp(w: RPath; db: HexaryTreeDB; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(RPath)"):
    result = w.path.pp(db,indent) & &"{pfx}({w.tail.pp})"

proc pp(w: RPathXStep; db: HexaryTreeDB): string =
  noPpError("pp(RPathXStep)"):
    let y = if w.canLock: "lockOk" else: "noLock"
    result = &"({w.pos},{y},{w.step.pp(db)})"

proc pp(w: seq[RPathXStep]; db: HexaryTreeDB; indent = 4): string =
  let pfx = "\n" & " ".repeat(indent)
  noPpError("pp(seq[RPathXStep])"):
    result = w.mapIt(it.pp(db)).join(pfx)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc dup(node: RNodeRef): RNodeRef =
  new result
  result[] = node[]


template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

# ------------------------------------------------------------------------------
# Private getters & setters
# ------------------------------------------------------------------------------

proc xPfx(node: RNodeRef): NibblesSeq =
  case node.kind:
  of Leaf:
    return node.lPfx
  of Extension:
    return node.ePfx
  of Branch:
    doAssert node.kind != Branch # Ooops

proc `xPfx=`(node: RNodeRef, val: NibblesSeq) =
  case node.kind:
  of Leaf:
    node.lPfx = val
  of Extension:
    node.ePfx = val
  of Branch:
    doAssert node.kind != Branch # Ooops

proc xData(node: RNodeRef): Blob =
  case node.kind:
  of Branch:
    return node.bData
  of Leaf:
    return node.lData
  of Extension:
    doAssert node.kind != Extension # Ooops

proc `xData=`(node: RNodeRef; val: Blob) =
  case node.kind:
  of Branch:
    node.bData = val
  of Leaf:
    node.lData = val
  of Extension:
    doAssert node.kind != Extension # Ooops

# ------------------------------------------------------------------------------
# Private functions, repair tree action helpers
# ------------------------------------------------------------------------------

proc rTreeExtendLeaf(
    db: var HexaryTreeDB;
    rPath: RPath;
    key: RepairKey
      ): RPath =
  ## Append a `Leaf` node to a `Branch` node (see `rTreeExtend()`.)
  if 0 < rPath.tail.len:
    let
      nibble = rPath.path[^1].nibble
      leaf = RNodeRef(
        state: Mutable,
        kind:  Leaf,
        lPfx:  rPath.tail)
    db.tab[key] = leaf
    if not key.isNodeKey:
      rPath.path[^1].node.bLink[nibble] = key
    return RPath(
      path: rPath.path & RPathStep(key: key, node: leaf, nibble: -1),
      tail: EmptyNibbleRange)

proc rTreeExtendLeaf(
    db: var HexaryTreeDB;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef
     ): RPath =
  ## Register `node` and append/link a `Leaf` node to a `Branch` node (see
  ## `rTreeExtend()`.)
  if 1 < rPath.tail.len and node.state == Mutable:
    let
      nibble = rPath.tail[0].int8
      xStep = RPathStep(key: key, node: node, nibble: nibble)
      xPath = RPath(path: rPath.path & xStep, tail: rPath.tail.slice(1))
    return db.rTreeExtendLeaf(xPath, db.newRepairKey())


proc rTreeSplitNode(
    db: var HexaryTreeDB;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef
     ): RPath =
  ## Replace `Leaf` or `Extension` node in tuple `(key,node)` by parts (see
  ## `rTreeExtend()`):
  ##
  ##   left(Extension) -> middle(Branch) -> right(Extension or Leaf)
  ##     ^                  ^
  ##     |                  |
  ##   added-to-path      added-to-path
  ##
  ## where either `left()` or `right()` extensions might be missing.
  ##
  let
    nibbles = node.xPfx
    lLen = rPath.tail.sharedPrefixLen(nibbles)
  if nibbles.len == 0 or rPath.tail.len <= lLen:
    return # Ooops      (^^^^^ otherwise `rPath` was not the longest)
  var
    mKey = key
  let
    mNibble = nibbles[lLen]           # exists as `lLen < tail.len`
    rPfx = nibbles.slice(lLen + 1)    # might be empty OK

  result = rPath

  # Insert node (if any): left(Extension)
  if 0 < lLen:
    let lNode = RNodeRef(
      state: Mutable,
      kind:  Extension,
      ePfx:  result.tail.slice(0,lLen),
      eLink: db.newRepairKey())
    db.tab[key] = lNode
    result.path.add RPathStep(key: key, node: lNode, nibble: -1)
    result.tail = result.tail.slice(lLen)
    mKey = lNode.eLink

  # Insert node: middle(Branch)
  let mNode = RNodeRef(
    state: Mutable,
    kind:  Branch)
  db.tab[mKey] = mNode
  result.path.add RPathStep(key: mKey, node: mNode, nibble: -1) # no nibble yet

  # Insert node (if any): right(Extension) -- not to be registered in `rPath`
  if 0 < rPfx.len:
    let rKey = db.newRepairKey()
    # Re-use argument node
    mNode.bLink[mNibble] = rKey
    db.tab[rKey] = node
    node.xPfx = rPfx
  # Otherwise merge argument node
  elif node.kind == Extension:
    mNode.bLink[mNibble] = node.eLink
  else:
    # Oops, does it make sense, at all?
    mNode.bData = node.lData

# ------------------------------------------------------------------------------
# Private functions, repair tree actions
# ------------------------------------------------------------------------------

proc rTreeFollow(
    nodeKey: NodeKey;
    db: var HexaryTreeDB
      ): RPath =
  ## Compute logest possible path matching the `nodeKey` nibbles.
  result.tail = nodeKey.to(NibblesSeq)
  noKeyError("rTreeFollow"):
    var key = db.rootKey.to(RepairKey)
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

proc rTreeFollow(
    nodeTag: NodeTag;
    db: var HexaryTreeDB
      ): RPath =
  ## Variant of `rTreeFollow()`
  nodeTag.to(NodeKey).rTreeFollow(db)


proc rTreeInterpolate(
    rPath: RPath;
    db: var HexaryTreeDB
      ): RPath =
  ## Extend path, add missing nodes to tree. The last node added will be
  ## a `Leaf` node if this function succeeds.
  ##
  ## The function assumed that the `RPath` argument is the longest possible
  ## as just constructed by `rTreeFollow()`
  if 0 < rPath.path.len and 0 < rPath.tail.len:
    noKeyError("rTreeExtend"):
      let step = rPath.path[^1]
      case step.node.kind:
      of Branch:
        # Now, the slot must not be empty. An empty slot would lead to a
        # rejection of this record as last valid step, contrary to the
        # assumption `path` is the longest one.
        if step.nibble < 0:
          return # sanitary check failed
        let key = step.node.bLink[step.nibble]
        if key.isZero:
          return # sanitary check failed

        # Case: unused slot => add leaf record
        if not db.tab.hasKey(key):
          return db.rTreeExtendLeaf(rPath, key)

        # So a `child` node exits but it is something that could not be used to
        # extend the argument `path` which is assumed the longest possible one.
        let child = db.tab[key]
        case child.kind:
        of Branch:
          # So a `Leaf` node can be linked into the `child` branch
          return db.rTreeExtendLeaf(rPath, key, child)

        # Need to split the right `grandChild` in `child -> grandChild`
        # into parts:
        #
        #   left(Extension) -> middle(Branch)
        #                         |   |
        #                         |   +-----> right(Extension or Leaf) ...
        #                         +---------> new Leaf record
        #
        # where either `left()` or `right()` extensions might be missing
        of Extension, Leaf:
          var xPath = db.rTreeSplitNode(rPath, key, child)
          if 0 < xPath.path.len:
            # Append `Leaf` node
            xPath.path[^1].nibble = xPath.tail[0].int8
            xPath.tail = xPath.tail.slice(1)
            return db.rTreeExtendLeaf(xPath, db.newRepairKey())
      of Leaf:
        return # Oops
      of Extension:
        let key = step.node.eLink

        var child: RNodeRef
        if db.tab.hasKey(key):
          child = db.tab[key]
          # `Extension` can only be followed by a `Branch` node
          if child.kind != Branch:
            return
        else:
          # Case: unused slot => add `Branch` and `Leaf` record
          child = RNodeRef(
            state: Mutable,
            kind:  Branch)
          db.tab[key] = child

        # So a `Leaf` node can be linked into the `child` branch
        return db.rTreeExtendLeaf(rPath, key, child)


proc rTreeInterpolate(
    rPath: RPath;
    db: var HexaryTreeDB;
    payload: Blob
      ): RPath =
  ## Variant of `rTreeExtend()` which completes a `Leaf` record.
  result = rPath.rTreeInterpolate(db)
  if 0 < result.path.len and result.tail.len == 0:
    let node = result.path[^1].node
    if node.kind != Extension and node.state == Mutable:
      node.xData = payload


proc rTreeUpdateKeys(
    rPath: RPath;
    db: var HexaryTreeDB
      ): Result[void,int] =
  ## The argument `rPath` is assumed to organise database nodes as
  ##
  ##    root -> ... -> () -> () -> ... -> () -> () ...
  ##     |-------------|     |------------|      |------
  ##      static nodes        locked nodes        mutable nodes
  ##
  ## Where
  ## * Static nodes are read-only nodes provided by the proof database
  ## * Locked nodes are added read-only nodes that satisfy the proof condition
  ## * Mutable nodes are incomplete nodes
  ##
  ## Then update nodes from the right end and set all the mutable nodes
  ## locked if possible.
  var
    rTop = rPath.path.len
    stack: seq[RPathXStep]

  if 0 < rTop and
     rPath.path[^1].node.state == Mutable and
     rPath.path[0].node.state != Mutable:

    # Set `Leaf` entry
    let leafNode = rPath.path[^1].node.dup
    stack.add RPathXStep(
      pos: rTop - 1,
      canLock: true,
      step: RPathStep(
        node: leafNode,
        key: leafNode.convertTo(Blob).digestTo(NodeKey).to(RepairKey),
        nibble: -1))

    while true:
      rTop.dec

      # Update parent node (note that `2 <= rPath.path.len`)
      let
        thisKey = stack[^1].step.key
        preStep = rPath.path[rTop-1]
        preNibble = preStep.nibble

      # End reached
      if preStep.node.state != Mutable:

        # Verify the tail matches
        var key = RepairKey.default
        case preStep.node.kind:
        of Branch:
          key = preStep.node.bLink[preNibble]
        of Extension:
          key = preStep.node.eLink
        of Leaf:
          discard
        if key != thisKey:
          return err(rTop-1)

        when RepairTreeDebugging:
          echo "*** rTreeUpdateKeys",
             " rPath\n    ", rPath.pp(ps),
             "\n    stack\n    ", stack.pp(ps)

        # Ok, replace database records by stack entries
        var lockOk = true
        for n in countDown(stack.len-1,0):
          let item = stack[n]
          db.tab.del(rPath.path[item.pos].key)
          db.tab[item.step.key] = item.step.node
          if lockOk:
            if item.canLock:
              item.step.node.state = Locked
            else:
              lockOk = false
        if not lockOk:
          return err(rTop-1) # repeat
        break # Done ok()

      stack.add RPathXStep(
        pos: rTop - 1,
        step: RPathStep(
          node: preStep.node.dup, # (!)
          nibble: preNibble,
          key: preStep.key))

      case stack[^1].step.node.kind:
      of Branch:
        stack[^1].step.node.bLink[preNibble] = thisKey
        # Check whether all keys are proper, non-temporary keys
        stack[^1].canLock = true
        for n in 0 ..< 16:
          if not stack[^1].step.node.bLink[n].isNodeKey:
            stack[^1].canLock = false
            break
      of Extension:
        stack[^1].step.node.eLink = thisKey
        stack[^1].canLock = thisKey.isNodeKey
      of Leaf:
        return err(rTop-1)

      # Must not overwrite a non-temprary key
      if stack[^1].canLock:
        stack[^1].step.key =
          stack[^1].step.node.convertTo(Blob).digestTo(NodeKey).to(RepairKey)

  ok()


# ------------------------------------------------------------------------------
# Public fuctions
# ------------------------------------------------------------------------------

proc hexary_interpolate*(db: var HexaryTreeDB): Result[void,HexaryDbError] =
  ## Verifiy accounts by interpolating the collected accounts on the hexary
  ## trie of the repair database. If all accounts can be represented in the
  ## hexary trie, they are vonsidered validated.
  ##
  # Walk top down and insert/complete missing account access nodes
  for n in countDown(db.acc.len-1,0):
    let acc = db.acc[n]
    if acc.payload.len != 0:
      let rPath = acc.pathTag.rTreeFollow(db)
      var repairKey = acc.nodeKey
      if repairKey.isZero and 0 < rPath.path.len and rPath.tail.len == 0:
        repairKey = rPath.path[^1].key
        db.acc[n].nodeKey = repairKey
      if repairKey.isZero:
        let
          update = rPath.rTreeInterpolate(db, acc.payload)
          final = acc.pathTag.rTreeFollow(db)
        if update != final:
          return err(AccountRepairBlocked)
        db.acc[n].nodeKey = rPath.path[^1].key

  # Replace temporary repair keys by proper hash based node keys.
  var reVisit: seq[NodeTag]
  for n in countDown(db.acc.len-1,0):
    let acc = db.acc[n]
    if not acc.nodeKey.isZero:
      let rPath = acc.pathTag.rTreeFollow(db)
      if rPath.path[^1].node.state == Mutable:
        let rc = rPath.rTreeUpdateKeys(db)
        if rc.isErr:
          reVisit.add acc.pathTag

  while 0 < reVisit.len:
    var again: seq[NodeTag]
    for nodeTag in reVisit:
      let rc = nodeTag.rTreeFollow(db).rTreeUpdateKeys(db)
      if rc.isErr:
        again.add nodeTag
    if reVisit.len <= again.len:
      return err(BoundaryProofFailed)
    reVisit = again

  ok()

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

proc dumpPath*(db: var HexaryTreeDB; key: NodeTag): seq[string] =
  ## Pretty print helper compiling the path into the repair tree for the
  ## argument `key`.
  let rPath = key.rTreeFollow(db)
  rPath.path.mapIt(it.pp(db)) & @["(" & rPath.tail.pp & ")"]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
