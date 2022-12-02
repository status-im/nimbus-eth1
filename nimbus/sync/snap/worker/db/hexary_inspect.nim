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

# --------
#
#import
#  std/strutils,
#  stew/byteutils
#
#proc pp(w: (RepairKey, NibblesSeq); db: HexaryTreeDbRef): string =
#  "(" & $w[1] & "," & w[0].pp(db) & ")"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(key: Blob; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc processLink(
    db: HexaryTreeDbRef;
    stats: var TrieNodeStat;
    inspect: var seq[(RepairKey,NibblesSeq)];
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
      inspect.add (child,trail)
    else:
      stats.dangling.add NodeSpecs(
        partialPath: trail.hexPrefixEncode(isLeaf = false),
        nodeKey:     child.convertTo(NodeKey))

proc processLink(
    getFn: HexaryGetFn;
    stats: var TrieNodeStat;
    inspect: var seq[(NodeKey,NibblesSeq)];
    trail: NibblesSeq;
    child: Rlp;
      ) {.gcsafe, raises: [Defect,RlpError]} =
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
        inspect.add (childKey,trail)
      else:
        stats.dangling.add NodeSpecs(
          partialPath: trail.hexPrefixEncode(isLeaf = false),
          nodeKey:     childKey)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc to*(resumeCtx: TrieNodeStatCtxRef; T: type seq[NodeSpecs]): T =
  ## Convert resumption context to nodes that can be used otherwise. This
  ## function might be useful for error recovery.
  ##
  ## Note: In a non-persistant case, temporary `RepairKey` type node specs
  ## that cannot be converted to `NodeKey` type nodes are silently dropped.
  ## This should be no problem as a hexary trie with `RepairKey` type node
  ## refs must be repaired or discarded anyway.
  if resumeCtx.persistent:
    for (key,trail) in resumeCtx.hddCtx:
      result.add NodeSpecs(
        partialPath: trail.hexPrefixEncode(isLeaf = false),
        nodeKey:     key)
  else:
    for (key,trail) in resumeCtx.memCtx:
      if key.isNodeKey:
        result.add NodeSpecs(
          partialPath: trail.hexPrefixEncode(isLeaf = false),
          nodeKey:     key.convertTo(NodeKey))


proc hexaryInspectTrie*(
    db: HexaryTreeDbRef;                 ## Database
    root: NodeKey;                       ## State root
    paths: seq[Blob] = @[];              ## Starting paths for search
    resumeCtx: TrieNodeStatCtxRef = nil; ## Context for resuming inspection
    suspendAfter = high(uint64);         ## To be resumed
    stopAtLevel = 64;                    ## Instead of loop detector
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
  ## Trie inspection can be automatically suspended after having visited
  ## `suspendAfter` nodes to be resumed at the last state. An application of
  ## this feature would look like
  ## ::
  ##   var ctx = TrieNodeStatCtxRef()
  ##   while not ctx.isNil:
  ##     let state = hexaryInspectTrie(db, root, paths, resumeCtx=ctx, 1024)
  ##     ...
  ##     ctx = state.resumeCtx
  ##
  let rootKey = root.to(RepairKey)
  if not db.tab.hasKey(rootKey):
    return TrieNodeStat()

  var
    reVisit: seq[(RepairKey,NibblesSeq)]
    again: seq[(RepairKey,NibblesSeq)]
    numActions = 0u64
    resumeOk = false

  # Initialise lists from previous session
  if not resumeCtx.isNil and
     not resumeCtx.persistent and
     0 < resumeCtx.memCtx.len:
    resumeOk = true
    reVisit = resumeCtx.memCtx

  if paths.len == 0 and not resumeOk:
    reVisit.add (rootKey,EmptyNibbleRange)
  else:
    # Add argument paths
    for w in paths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = nibbles.hexaryPathNodeKey(rootKey, db, missingOk=false)
        if rc.isOk:
          reVisit.add (rc.value.to(RepairKey), nibbles)

  while 0 < reVisit.len and numActions <= suspendAfter:
    if stopAtLevel < result.level:
      result.stopped = true
      break

    for n in 0 ..< reVisit.len:
      let (rKey,parentTrail) = reVisit[n]
      if suspendAfter < numActions:
        # Swallow rest
        again = again & reVisit[n ..< reVisit.len]
        break

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

      numActions.inc
      # End `for`

    result.level.inc
    swap(reVisit, again)
    again.setLen(0)
    # End while

  if 0 < reVisit.len:
    result.resumeCtx = TrieNodeStatCtxRef(
      persistent: false,
      memCtx:     reVisit)


proc hexaryInspectTrie*(
    getFn: HexaryGetFn;                  ## Database abstraction
    rootKey: NodeKey;                    ## State root
    paths: seq[Blob] = @[];              ## Starting paths for search
    resumeCtx: TrieNodeStatCtxRef = nil; ## Context for resuming inspection
    suspendAfter = high(uint64);         ## To be resumed
    stopAtLevel = 64;                    ## Instead of loop detector
      ): TrieNodeStat
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Variant of `hexaryInspectTrie()` for persistent database.
  when extraTraceMessages:
    let nPaths = paths.len

  let root = rootKey.to(Blob)
  if root.getFn().len == 0:
    when extraTraceMessages:
      trace "Hexary inspect: missing root", nPaths, maxLeafPaths,
        rootKey=root.toHex
    return TrieNodeStat()

  var
    reVisit: seq[(NodeKey,NibblesSeq)]
    again: seq[(NodeKey,NibblesSeq)]
    numActions = 0u64
    resumeOk = false

  # Initialise lists from previous session
  if not resumeCtx.isNil and
     resumeCtx.persistent and
     0 < resumeCtx.hddCtx.len:
    resumeOk = true
    reVisit = resumeCtx.hddCtx

  if paths.len == 0 and not resumeOk:
    reVisit.add (rootKey,EmptyNibbleRange)
  else:
    # Add argument paths
    for w in paths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = nibbles.hexaryPathNodeKey(rootKey, getFn, missingOk=false)
        if rc.isOk:
          reVisit.add (rc.value, nibbles)

  while 0 < reVisit.len and numActions <= suspendAfter:
    when extraTraceMessages:
      trace "Hexary inspect processing", nPaths, maxLeafPaths,
        level=result.level, nReVisit=reVisit.len, nDangling=result.dangling.len

    if stopAtLevel < result.level:
      result.stopped = true
      break

    for n in 0 ..< reVisit.len:
      let (parent,parentTrail) = reVisit[n]
      if suspendAfter < numActions:
        # Swallow rest
        again = again & reVisit[n ..< reVisit.len]
        break

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

      numActions.inc
      # End `for`

    result.level.inc
    swap(reVisit, again)
    again.setLen(0)
    # End while

  if 0 < reVisit.len:
    result.resumeCtx = TrieNodeStatCtxRef(
      persistent: true,
      hddCtx:     reVisit)

  when extraTraceMessages:
    trace "Hexary inspect finished", nPaths, maxLeafPaths,
      level=result.level, nResumeCtx=reVisit.len, nDangling=result.dangling.len,
      maxLevel=stopAtLevel, stopped=result.stopped

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
