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
  std/[hashes, sequtils, sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_desc, hexary_paths]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false # or true

when extraTraceMessages:
  import stew/byteutils

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(key: Blob; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key)

proc doStepLink(step: RPathStep): Result[RepairKey,bool] =
  ## Helper for `hexaryInspectPath()` variant
  case step.node.kind:
  of Branch:
    if step.nibble < 0:
      return err(false) # indicates caller should try parent
    return ok(step.node.bLink[step.nibble])
  of Extension:
    return ok(step.node.eLink)
  of Leaf:
    discard
  err(true) # fully fail

proc doStepLink(step: XPathStep): Result[NodeKey,bool] =
  ## Helper for `hexaryInspectPath()` variant
  case step.node.kind:
  of Branch:
    if step.nibble < 0:
      return err(false) # indicates caller should try parent
    return ok(step.node.bLink[step.nibble].convertTo(NodeKey))
  of Extension:
    return ok(step.node.eLink.convertTo(NodeKey))
  of Leaf:
    discard
  err(true) # fully fail


proc hexaryInspectPathImpl(
    db: HexaryTreeDbRef;           ## Database
    rootKey: RepairKey;            ## State root
    path: NibblesSeq;              ## Starting path
      ): Result[RepairKey,void]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Translate `path` into `RepairKey`
  let steps = path.hexaryPath(rootKey,db)
  if 0 < steps.path.len and steps.tail.len == 0:
    block:
      let rc = steps.path[^1].doStepLink()
      if rc.isOk:
         return ok(rc.value)
      if rc.error or steps.path.len == 1:
        return err()
    block:
      let rc = steps.path[^2].doStepLink()
      if rc.isOk:
         return ok(rc.value)
  err()

proc hexaryInspectPathImpl(
    getFn: HexaryGetFn;            ## Database retrieval function
    root: NodeKey;                 ## State root
    path: NibblesSeq;              ## Starting path
      ): Result[NodeKey,void]
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Translate `path` into `RepairKey`
  let steps = path.hexaryPath(root,getFn)
  if 0 < steps.path.len and steps.tail.len == 0:
    block:
      let rc = steps.path[^1].doStepLink()
      if rc.isOk:
         return ok(rc.value)
      if rc.error or steps.path.len == 1:
        return err()
    block:
      let rc = steps.path[^2].doStepLink()
      if rc.isOk:
         return ok(rc.value)
  err()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc processLink(
    db: HexaryTreeDbRef;
    stats: var TrieNodeStat;
    inspect: TableRef[RepairKey,NibblesSeq];
    trail: NibblesSeq;
    child: RepairKey;
      ) {.gcsafe, raises: [Defect,KeyError]} =
  ## Helper for `hexaryInspect()`
  if not child.isZero:
    if not child.isNodeKey:
      # Oops -- caught in the middle of a repair process? Just register
      # this node
      stats.dangling.add NodeSpecs(
        partialPath: trail.hexPrefixEncode(isLeaf = false))
    elif db.tab.hasKey(child):
      inspect[child] = trail
    else:
      stats.dangling.add NodeSpecs(
        partialPath: trail.hexPrefixEncode(isLeaf = false),
        nodeKey:     child.convertTo(NodeKey))

proc processLink(
    getFn: HexaryGetFn;
    stats: var TrieNodeStat;
    inspect: TableRef[NodeKey,NibblesSeq];
    trail: NibblesSeq;
    child: Rlp;
      ) {.gcsafe, raises: [Defect,RlpError,KeyError]} =
  ## Ditto
  if not child.isEmpty:
    let childBlob = child.toBytes
    if childBlob.len != 32:
      # Oops -- that is wrong, although the only sensible action is to
      # register the node and otherwise ignore it
      stats.dangling.add NodeSpecs(
        partialPath: trail.hexPrefixEncode(isLeaf = false))
    else:
      let childKey = childBlob.convertTo(NodeKey)
      if 0 < child.toBytes.getFn().len:
        inspect[childKey] = trail
      else:
        stats.dangling.add NodeSpecs(
          partialPath: trail.hexPrefixEncode(isLeaf = false),
          nodeKey:     childKey)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hexaryInspectPath*(
    db: HexaryTreeDbRef;           ## Database
    root: NodeKey;                 ## State root
    path: Blob;                    ## Starting path
      ): Result[NodeKey,void]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Returns the `NodeKey` for a given path if there is any.
  let (isLeaf,nibbles) = hexPrefixDecode path
  if not isLeaf:
    let rc = db.hexaryInspectPathImpl(root.to(RepairKey), nibbles)
    if rc.isOk and rc.value.isNodeKey:
      return ok(rc.value.convertTo(NodeKey))
  err()

proc hexaryInspectPath*(
    getFn: HexaryGetFn;            ## Database abstraction
    root: NodeKey;                 ## State root
    path: Blob;                    ## Partial database path
      ): Result[NodeKey,void]
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `hexaryInspectPath()` for persistent database.
  let (isLeaf,nibbles) = hexPrefixDecode path
  if not isLeaf:
    let rc = getFn.hexaryInspectPathImpl(root, nibbles)
    if rc.isOk:
      return ok(rc.value)
  err()

proc hexaryInspectToKeys*(
    db: HexaryTreeDbRef;           ## Database
    root: NodeKey;                 ## State root
    paths: seq[Blob];              ## Paths segments
      ): HashSet[NodeKey]
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Convert a set of path segments to a node key set
  paths.toSeq
       .mapIt(db.hexaryInspectPath(root,it))
       .filterIt(it.isOk)
       .mapIt(it.value)
       .toHashSet


proc hexaryInspectTrie*(
    db: HexaryTreeDbRef;           ## Database
    root: NodeKey;                 ## State root
    paths: seq[Blob];              ## Starting paths for search
    stopAtLevel = 32;              ## Instead of loop detector
      ): TrieNodeStat
      {.gcsafe, raises: [Defect,KeyError]} =
  ## Starting with the argument list `paths`, find all the non-leaf nodes in
  ## the hexary trie which have at least one node key reference missing in
  ## the trie database. The references for these nodes are collected and
  ## returned.
  ## * Search list `paths` argument entries that do not refer to a hexary node
  ##   are ignored.
  ## * For any search list `paths` argument entry, this function stops if
  ##   the search depth exceeds `stopAtLevel` levels of linked sub-nodes.
  ## * Argument `paths` list entries and partial paths on the way that do not
  ##   refer to a valid extension or branch type node are silently ignored.
  ##
  let rootKey = root.to(RepairKey)
  if not db.tab.hasKey(rootKey):
    return TrieNodeStat()

  # Initialise TODO list
  var reVisit = newTable[RepairKey,NibblesSeq]()
  if paths.len == 0:
    reVisit[rootKey] = EmptyNibbleRange
  else:
    for w in paths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = db.hexaryInspectPathImpl(rootKey, nibbles)
        if rc.isOk:
          reVisit[rc.value] = nibbles

  while 0 < reVisit.len:
    if stopAtLevel < result.level:
      result.stopped = true
      break

    let again = newTable[RepairKey,NibblesSeq]()

    for rKey,parentTrail in reVisit.pairs:
      let
        node = db.tab[rKey]
        parent = rKey.convertTo(NodeKey)

      case node.kind:
      of Extension:
        let
          trail = parentTrail & node.ePfx
          child = node.eLink
        db.processLink(stats=result, inspect=again, trail, child)
      of Branch:
        for n in 0 ..< 16:
          let
            trail = parentTrail & @[n.byte].initNibbleRange.slice(1)
            child = node.bLink[n]
          db.processLink(stats=result, inspect=again, trail, child)
      of Leaf:
        # Ooops, forget node and key
        discard

      # End `for`

    result.level.inc
    reVisit = again
    # End while


proc hexaryInspectTrie*(
    getFn: HexaryGetFn;            ## Database abstraction
    rootKey: NodeKey;              ## State root
    paths: seq[Blob];              ## Starting paths for search
    stopAtLevel = 32;              ## Instead of loop detector
      ): TrieNodeStat
      {.gcsafe, raises: [Defect,RlpError,KeyError]} =
  ## Variant of `hexaryInspectTrie()` for persistent database.
  when extraTraceMessages:
    let nPaths = paths.len

  let root = rootKey.to(Blob)
  if root.getFn().len == 0:
    when extraTraceMessages:
      trace "Hexary inspect: missing root", nPaths, maxLeafPaths,
        rootKey=root.toHex
    return TrieNodeStat()

  # Initialise TODO list
  var reVisit = newTable[NodeKey,NibblesSeq]()
  if paths.len == 0:
    reVisit[rootKey] = EmptyNibbleRange
  else:
    for w in paths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = getFn.hexaryInspectPathImpl(rootKey, nibbles)
        if rc.isOk:
          reVisit[rc.value] = nibbles

  while 0 < reVisit.len:
    when extraTraceMessages:
      trace "Hexary inspect processing", nPaths, maxLeafPaths,
        level=result.level, nReVisit=reVisit.len, nDangling=result.dangling.len

    if stopAtLevel < result.level:
      result.stopped = true
      break

    let again = newTable[NodeKey,NibblesSeq]()

    for parent,parentTrail in reVisit.pairs:

      let parentBlob = parent.to(Blob).getFn()
      if parentBlob.len == 0:
        # Ooops, forget node and key
        continue

      let nodeRlp = rlpFromBytes parentBlob
      case nodeRlp.listLen:
      of 2:
        let (isLeaf,xPfx) = hexPrefixDecode nodeRlp.listElem(0).toBytes
        if not isleaf:
          let
            trail = parentTrail & xPfx
            child = nodeRlp.listElem(1)
          getFn.processLink(stats=result, inspect=again, trail, child)
      of 17:
        for n in 0 ..< 16:
          let
            trail = parentTrail & @[n.byte].initNibbleRange.slice(1)
            child = nodeRlp.listElem(n)
          getFn.processLink(stats=result, inspect=again, trail, child)
      else:
        # Ooops, forget node and key
        discard
      # End `for`

    result.level.inc
    reVisit = again
    # End while

  when extraTraceMessages:
    trace "Hexary inspect finished", nPaths, maxLeafPaths,
      level=result.level, nReVisit=reVisit.len, nDangling=result.dangling.len,
      maxLevel=stopAtLevel, stopped=result.stopped

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
