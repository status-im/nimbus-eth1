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
  std/[sequtils, strutils, tables],
  chronicles,
  eth/[common, trie/nibbles],
  stew/results,
  ../../range_desc,
  "."/[hexary_desc, hexary_paths]

{.push raises: [].}

logScope:
  topics = "snap-db"

type
  TrieNodeStatCtxRef* = ref object
    ## Context to resume searching for dangling links
    case persistent*: bool
    of true:
      hddCtx*: seq[(NodeKey,NibblesSeq)]
    else:
      memCtx*: seq[(RepairKey,NibblesSeq)]

  TrieNodeStat* = object
    ## Trie inspection report
    dangling*: seq[NodeSpecs]       ## Referes to nodes with incomplete refs
    count*: uint64                  ## Number of nodes visited
    level*: uint8                   ## Maximum nesting depth of dangling nodes
    stopped*: bool                  ## Potential loop detected if `true`
    resumeCtx*: TrieNodeStatCtxRef  ## Context for resuming inspection

const
  extraTraceMessages = false # or true

when extraTraceMessages:
  import stew/byteutils

# ------------------------------------------------------------------------------
# Private helpers, debugging
# ------------------------------------------------------------------------------

proc ppDangling(a: seq[NodeSpecs]; maxItems = 30): string =
  proc ppBlob(w: Blob): string =
    w.mapIt(it.toHex(2)).join.toLowerAscii
  let
    q = a.mapIt(it.partialPath.ppBlob)[0 ..< min(maxItems,a.len)]
    andMore = if maxItems < a.len: ", ..[#" & $a.len & "].." else: ""
  "{" & q.join(",") & andMore & "}"

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
      ) =
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
      ) {.gcsafe, raises: [CatchableError]} =
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
    db: HexaryTreeDbRef;                 # Database
    root: NodeKey;                       # State root
    partialPaths: seq[Blob] = @[];       # Starting paths for search
    resumeCtx: TrieNodeStatCtxRef = nil; # Context for resuming inspection
    suspendAfter = high(uint64);         # To be resumed
    stopAtLevel = 64u8;                  # Width-first depth level
    maxDangling = high(int);             # Maximal number of dangling results
      ): TrieNodeStat
      {.gcsafe, raises: [KeyError]} =
  ## Starting with the argument list `paths`, find all the non-leaf nodes in
  ## the hexary trie which have at least one node key reference missing in
  ## the trie database. The references for these nodes are collected and
  ## returned.
  ##
  ## * Argument `partialPaths` list entries that do not refer to an existing
  ##   and allocated hexary trie node are silently ignored. So are enytries
  ##   that not refer to either a valid extension or a branch type node.
  ##
  ## * This function traverses the hexary trie in *width-first* mode
  ##   simultaneously for any entry of the argument `partialPaths` list. Abart
  ##   from completing the search there are three conditions when the search
  ##   pauses to return the current state (via `resumeCtx`, see next bullet
  ##   point):
  ##   + The depth level of the running algorithm exceeds `stopAtLevel`.
  ##   + The number of visited nodes exceeds `suspendAfter`.
  ##   + Te number of cunnently collected dangling nodes exceeds `maxDangling`.
  ##   If the function pauses because the current depth exceeds `stopAtLevel`
  ##   then the `stopped` flag of the result object will be set, as well.
  ##
  ## * When paused for some of the reasons listed above, the `resumeCtx` field
  ##   of the result object contains the current state so that the function
  ##   can resume searching from where is paused. An application using this
  ##   feature could look like:
  ##   ::
  ##     var ctx = TrieNodeStatCtxRef()
  ##     while not ctx.isNil:
  ##       let state = hexaryInspectTrie(db, root, paths, resumeCtx=ctx, 1024)
  ##       ...
  ##       ctx = state.resumeCtx
  ##
  let rootKey = root.to(RepairKey)
  if not db.tab.hasKey(rootKey):
    return TrieNodeStat()

  var
    reVisit: seq[(RepairKey,NibblesSeq)]
    again: seq[(RepairKey,NibblesSeq)]
    resumeOk = false

  # Initialise lists from previous session
  if not resumeCtx.isNil and
     not resumeCtx.persistent and
     0 < resumeCtx.memCtx.len:
    resumeOk = true
    reVisit = resumeCtx.memCtx

  if partialPaths.len == 0 and not resumeOk:
    reVisit.add (rootKey,EmptyNibbleRange)
  else:
    # Add argument paths
    for w in partialPaths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = nibbles.hexaryPathNodeKey(rootKey, db, missingOk=false)
        if rc.isOk:
          reVisit.add (rc.value.to(RepairKey), nibbles)

  # Stopping on `suspendAfter` has precedence over `stopAtLevel`
  while 0 < reVisit.len and result.count <= suspendAfter:
    if stopAtLevel < result.level:
      result.stopped = true
      break

    for n in 0 ..< reVisit.len:
      if suspendAfter < result.count or
         maxDangling <= result.dangling.len:
        # Swallow rest
        again &= reVisit[n ..< reVisit.len]
        break

      let
        (rKey, parentTrail) = reVisit[n]
        node = db.tab[rKey]
        # parent = rKey.convertTo(NodeKey) -- unused

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

      result.count.inc
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
    getFn: HexaryGetFn;                  # Database abstraction
    rootKey: NodeKey;                    # State root
    partialPaths: seq[Blob] = @[];       # Starting paths for search
    resumeCtx: TrieNodeStatCtxRef = nil; # Context for resuming inspection
    suspendAfter = high(uint64);         # To be resumed
    stopAtLevel = 64u8;                  # Width-first depth level
    maxDangling = high(int);             # Maximal number of dangling results
      ): TrieNodeStat
      {.gcsafe, raises: [CatchableError]} =
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
    resumeOk = false

  # Initialise lists from previous session
  if not resumeCtx.isNil and
     resumeCtx.persistent and
     0 < resumeCtx.hddCtx.len:
    resumeOk = true
    reVisit = resumeCtx.hddCtx

  if partialPaths.len == 0 and not resumeOk:
    reVisit.add (rootKey,EmptyNibbleRange)
  else:
    # Add argument paths
    for w in partialPaths:
      let (isLeaf,nibbles) = hexPrefixDecode w
      if not isLeaf:
        let rc = nibbles.hexaryPathNodeKey(rootKey, getFn, missingOk=false)
        if rc.isOk:
          reVisit.add (rc.value, nibbles)

  # Stopping on `suspendAfter` has precedence over `stopAtLevel`
  while 0 < reVisit.len and result.count <= suspendAfter:
    when extraTraceMessages:
      trace "Hexary inspect processing", nPaths, maxLeafPaths,
        level=result.level, nReVisit=reVisit.len, nDangling=result.dangling.len

    if stopAtLevel < result.level:
      result.stopped = true
      break

    for n in 0 ..< reVisit.len:
      if suspendAfter < result.count or
         maxDangling <= result.dangling.len:
        # Swallow rest
        again = again & reVisit[n ..< reVisit.len]
        break

      let
        (parent, parentTrail) = reVisit[n]
        parentBlob = parent.to(Blob).getFn()
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

      result.count.inc
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
# Public functions, debugging
# ------------------------------------------------------------------------------

proc pp*(a: TrieNodeStat; db: HexaryTreeDbRef; maxItems = 30): string =
  result = "(" & $a.level
  if a.stopped:
    result &= "stopped,"
  result &= $a.dangling.len & "," &
    a.dangling.ppDangling(maxItems) & ")"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
