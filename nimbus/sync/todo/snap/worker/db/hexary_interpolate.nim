# nimbus-eth1
# Copyright (c) 2021-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  std/[tables],
  eth/[common, trie/nibbles],
  results,
  "../.."/[constants, range_desc],
  "."/[hexary_desc, hexary_error, hexary_paths]

type
  RPathXStep = object
    ## Extended `RPathStep` needed for `NodeKey` assignmant
    pos*: int                         ## Some position into `seq[RPathStep]`
    step*: RPathStep                  ## Modified copy of an `RPathStep`
    canLock*: bool                    ## Can set `Locked` state

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

when false:
  import std/[sequtils, strutils]

  proc pp(w: RPathXStep; db: HexaryTreeDbRef): string =
    let y = if w.canLock: "lockOk" else: "noLock"
    "(" & $w.pos & "," & y & "," & w.step.pp(db) & ")"

  proc pp(w: seq[RPathXStep]; db: HexaryTreeDbRef; indent = 4): string =
    let pfx = "\n" & " ".repeat(indent)
    w.mapIt(it.pp(db)).join(pfx)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc dup(node: RNodeRef): RNodeRef =
  new result
  result[] = node[]

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

#proc xData(node: RNodeRef): Blob =
#  case node.kind:
#  of Branch:
#    return node.bData
#  of Leaf:
#    return node.lData
#  of Extension:
#    doAssert node.kind != Extension # Ooops

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
    db: HexaryTreeDbRef;
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
      root: rPath.root,
      path: rPath.path & RPathStep(key: key, node: leaf, nibble: -1),
      tail: EmptyNibbleSeq)

proc rTreeExtendLeaf(
    db: HexaryTreeDbRef;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef;
     ): RPath =
  ## Register `node` and append/link a `Leaf` node to a `Branch` node (see
  ## `rTreeExtend()`.)
  if 1 < rPath.tail.len and node.state in {Mutable,TmpRoot}:
    let
      nibble = rPath.tail[0].int8
      xStep = RPathStep(key: key, node: node, nibble: nibble)
      xPath = RPath(
        root: rPath.root,
        path: rPath.path & xStep,
        tail: rPath.tail.slice(1))
    return db.rTreeExtendLeaf(xPath, db.newRepairKey())


proc rTreeSplitNode(
    db: HexaryTreeDbRef;
    rPath: RPath;
    key: RepairKey;
    node: RNodeRef;
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

proc rTreeInterpolate(
    rPath: RPath;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Extend path, add missing nodes to tree. The last node added will be
  ## a `Leaf` node if this function succeeds.
  ##
  ## The function assumed that the `RPath` argument is the longest possible
  ## as just constructed by `pathExtend()`
  if 0 < rPath.path.len and 0 < rPath.tail.len:
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
    db: HexaryTreeDbRef;
    payload: Blob;
      ): RPath
      {.gcsafe, raises: [KeyError]} =
  ## Variant of `rTreeExtend()` which completes a `Leaf` record.
  result = rPath.rTreeInterpolate(db)
  if 0 < result.path.len and result.tail.len == 0:
    let node = result.path[^1].node
    if node.kind != Extension and node.state in {Mutable,TmpRoot}:
      node.xData = payload


proc rTreeUpdateKeys(
    rPath: RPath;
    db: HexaryTreeDbRef;
      ): Result[void,bool]
      {.gcsafe, raises: [KeyError].} =
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
  ##
  ## On error, a boolean value is returned indicating whether there were some
  ## significant changes made to the database, ie. some nodes could be locked.
  var
    rTop = rPath.path.len
    stack: seq[RPathXStep]
    changed = false

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

    while 1 < rTop:
      rTop.dec

      # Update parent node (note that `2 <= rPath.path.len`)
      let
        thisKey = stack[^1].step.key
        preStep = rPath.path[rTop-1]
        preNibble = preStep.nibble

      # End reached
      if preStep.node.state notin {Mutable,TmpRoot}:

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
          if not db.tab.hasKey(key) or
             db.tab[key].state notin {Mutable,TmpRoot}:
            return err(false) # no changes were made

        # Ok, replace database records by stack entries
        var lockOk = true
        for n in countDown(stack.len-1,0):
          let item = stack[n]
          db.tab.del(rPath.path[item.pos].key)
          db.tab[item.step.key] = item.step.node
          if lockOk:
            if item.canLock:
              changed = true
              item.step.node.state = Locked
            else:
              lockOk = false
        if not lockOk:
          return err(changed)
        return ok() # Done ok()

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
        return err(false) # no changes were made

      # Must not overwrite a non-temprary key
      if stack[^1].canLock:
        stack[^1].step.key =
          stack[^1].step.node.convertTo(Blob).digestTo(NodeKey).to(RepairKey)

      # End while 1 < rTop

    if stack[0].step.node.state != Mutable:
      # Nothing that can be done, here
      return err(false) # no changes were made

    # Ok, replace database records by stack entries
    block:
      var lockOk = true
      for n in countDown(stack.len-1,0):
        let item = stack[n]
        if item.step.node.state == TmpRoot:
          db.tab[rPath.path[item.pos].key] = item.step.node
        else:
          db.tab.del(rPath.path[item.pos].key)
          db.tab[item.step.key] = item.step.node
          if lockOk:
            if item.canLock:
              changed = true
              item.step.node.state = Locked
            else:
              lockOk = false
      if not lockOk:
        return err(changed)
    # Done ok()

  ok()

# ------------------------------------------------------------------------------
# Private functions for proof-less (i.e. empty) databases
# ------------------------------------------------------------------------------

proc rTreeBranchAppendleaf(
    db: HexaryTreeDbRef;
    bNode: RNodeRef;
    leaf: RLeafSpecs;
     ): bool =
  ## Database prefill helper.
  let nibbles = leaf.pathTag.to(NodeKey).ByteArray32.initNibbleRange
  if bNode.bLink[nibbles[0]].isZero:
    let key = db.newRepairKey()
    bNode.bLink[nibbles[0]] = key
    db.tab[key] = RNodeRef(
      state: Mutable,
      kind:  Leaf,
      lPfx:  nibbles.slice(1),
      lData: leaf.payload)
    return true

proc rTreePrefill(
    db: HexaryTreeDbRef;
    rootKey: NodeKey;
    dbItems: var seq[RLeafSpecs];
      ) =
  ## Fill missing root node.
  let nibbles = dbItems[^1].pathTag.to(NodeKey).ByteArray32.initNibbleRange
  if dbItems.len == 1:
    db.tab[rootKey.to(RepairKey)] = RNodeRef(
      state: TmpRoot,
      kind:  Leaf,
      lPfx:  nibbles,
      lData: dbItems[^1].payload)
  else:
    # let key = db.newRepairKey() -- notused
    var node = RNodeRef(
      state: TmpRoot,
      kind:  Branch)
    discard db.rTreeBranchAppendleaf(node, dbItems[^1])
    db.tab[rootKey.to(RepairKey)] = node

proc rTreeSquashRootNode(
    db: HexaryTreeDbRef;
    rootKey: NodeKey;
      ): RNodeRef
      {.gcsafe, raises: [KeyError].} =
  ## Handle fringe case and return root node. This function assumes that the
  ## root node has been installed, already. This function will check the root
  ## node for a combination `Branch->Extension/Leaf` for a single child root
  ## branch node and replace the pair by a single extension or leaf node. In
  ## a similar fashion, a combination `Branch->Branch` for a single child root
  ## is replaced by a `Extension->Branch` combination.
  let
    rootRKey = rootKey.to(RepairKey)
    node = db.tab[rootRKey]
  if node.kind == Branch:
    # Check whether there is more than one link, only
    var (nextKey, nibble) = (RepairKey.default, -1)
    for inx in 0 ..< 16:
      if not node.bLink[inx].isZero:
        if 0 <= nibble:
          return node # Nothing to do here
        (nextKey, nibble) = (node.bLink[inx], inx)
    if 0 <= nibble and db.tab.hasKey(nextKey):
      # Ok, exactly one link
      let
        nextNode = db.tab[nextKey]
        nibblePfx = @[nibble.byte].initNibbleRange.slice(1)
      if nextNode.kind == Branch:
        # Replace root node by an extension node
        let thisNode = RNodeRef(
          kind:  Extension,
          ePfx:  nibblePfx,
          eLink: nextKey)
        db.tab[rootRKey] = thisNode
        return thisNode
      else:
        # Nodes can be squashed: the child node replaces the root node
        nextNode.xPfx = nibblePfx & nextNode.xPfx
        db.tab.del(nextKey)
        db.tab[rootRKey] = nextNode
        return nextNode

  return node

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryInterpolate*(
    db: HexaryTreeDbRef;           # Database
    rootKey: NodeKey;              # Root node hash
    dbItems: var seq[RLeafSpecs];  # List of path and leaf items
    bootstrap = false;             # Can create root node on-the-fly
      ): Result[void,HexaryError]
      {.gcsafe, raises: [CatchableError]} =
  ## From the argument list `dbItems`, leaf nodes will be added to the hexary
  ## trie while interpolating the path for the leaf nodes by adding  missing
  ## nodes. This action is typically not a full trie rebuild. Some partial node
  ## entries might have been added, already which is typical for a boundary
  ## proof that comes with the `snap/1` protocol.
  ##
  ## If successful, there will be a complete hexary trie avaliable with the
  ## `payload` fields of the `dbItems` argument list as leaf node values. The
  ## argument list `dbItems` will have been updated by registering the node
  ## keys of the leaf items.
  ##
  ## The algorithm employed here tries to minimise hashing hexary nodes for
  ## the price of re-vising the same node again.
  ##
  ## When interpolating, a skeleton of the hexary trie is constructed first
  ## using temorary keys instead of node hashes.
  ##
  ## In a second run, all these temporary keys are replaced by proper node
  ## hashes so that each node will be hashed only once.
  ##
  if dbItems.len == 0:
    return ok() # nothing to do

  # Handle bootstrap, dangling `rootKey`. This mode adds some pseudo
  # proof-nodes in order to keep the algoritm going.
  var addedRootNode = false
  if not db.tab.hasKey(rootKey.to(RepairKey)):
    if not bootstrap:
      return err(RootNodeMissing)
    addedRootNode = true
    db.rTreePrefill(rootKey, dbItems)

  # ---------------------------------------
  # Construnct skeleton with temporary keys
  # ---------------------------------------

  # Walk top down and insert/complete missing account access nodes
  for n in (dbItems.len-1).countDown(0):
    let dbItem = dbItems[n]
    if dbItem.payload.len != 0:
      var
        rPath = dbItem.pathTag.hexaryPath(rootKey, db)
        repairKey = dbItem.nodeKey
      if rPath.path.len == 0 and addedRootNode:
        let node = db.tab[rootKey.to(RepairKey)]
        if db.rTreeBranchAppendleaf(node, dbItem):
          rPath = dbItem.pathTag.hexaryPath(rootKey, db)
      if repairKey.isZero and 0 < rPath.path.len and rPath.tail.len == 0:
        repairKey = rPath.path[^1].key
        dbItems[n].nodeKey = repairKey
      if repairKey.isZero:
        let
          update = rPath.rTreeInterpolate(db, dbItem.payload)
          final = dbItem.pathTag.hexaryPath(rootKey, db)
        if update != final:
          return err(AccountRepairBlocked)
        dbItems[n].nodeKey = rPath.path[^1].key

  # --------------------------------------------
  # Replace temporary keys by proper node hashes
  # --------------------------------------------

  # Replace temporary repair keys by proper hash based node keys.
  var reVisit: seq[NodeTag]
  for n in countDown(dbItems.len-1,0):
    let dbItem = dbItems[n]
    if not dbItem.nodeKey.isZero:
      let rPath = dbItem.pathTag.hexaryPath(rootKey, db)
      if rPath.path[^1].node.state == Mutable:
        let rc = rPath.rTreeUpdateKeys(db)
        if rc.isErr:
          reVisit.add dbItem.pathTag

  while 0 < reVisit.len:
    var
      again: seq[NodeTag]
      changed = false
    for n,nodeTag in reVisit:
      let rc = nodeTag.hexaryPath(rootKey, db).rTreeUpdateKeys(db)
      if rc.isErr:
        again.add nodeTag
        if rc.error:
          changed = true
    if reVisit.len <= again.len and not changed:
      if addedRootNode:
        return err(InternalDbInconsistency)
      return err(RightBoundaryProofFailed)
    reVisit = again

  # Update root node (if any). If the root node was constructed from scratch,
  # it must be consistent.
  if addedRootNode:
    let node = db.rTreeSquashRootNode(rootKey)
    if rootKey != node.convertTo(Blob).digestTo(NodeKey):
      return err(RootNodeMismatch)
    node.state = Locked

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
