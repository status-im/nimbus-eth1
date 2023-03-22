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
  "../.."/[constants, range_desc],
  "."/[hexary_desc, hexary_nodes_helper]

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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc rootPathExtend(
    path: RPath|XPath;                    # Partially expanded path
    db: HexaryTreeDbRef|HexaryGetFn;      # Database abstraction
      ): auto
      {.gcsafe, raises: [CatchableError].} =
  ## For the given path, extend to the longest possible `db` database
  ## path following the argument `path.tail`.
  result = path

  when typeof(path) is RPath:
    var key = path.root
  else:
    var key = path.root.to(Blob)

  while true:
    let rc = key.getNode(db)
    if rc.isErr:
      break
    let node = rc.value

    case node.kind:
    of Leaf:
      if result.tail.len == result.tail.sharedPrefixLen(node.lPfx):
        # Bingo, got full path
        result.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
        result.tail = EmptyNibbleSeq
      return

    of Branch:
      if result.tail.len == 0:
        result.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
        return
      let nibble = result.tail[0].int8
      if node.bLink[nibble].isZeroLink:
        return
      result.path.add typeof(path.path[0])(key: key, node: node, nibble: nibble)
      result.tail = result.tail.slice(1)
      key = node.bLink[nibble]

    of Extension:
      if result.tail.len == 0:
        result.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
        result.tail = EmptyNibbleSeq # clean up internal indexing
        return
      if node.ePfx.len != result.tail.sharedPrefixLen(node.ePfx):
        return
      result.path.add typeof(path.path[0])(key: key, node: node, nibble: -1)
      result.tail = result.tail.slice(node.ePfx.len)
      key = node.eLink

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
      {.gcsafe, raises: [CatchableError]} =
  ## Compute the longest possible repair tree `db` path matching the `nodeKey`
  ## nibbles. The `nodeNey` path argument comes before the `db` one for
  ## supporting a more functional notation.
  RPath(root: rootKey.to(RepairKey), tail: partialPath).rootPathExtend(db)

proc hexaryPath*(
    nodeKey: NodeKey;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a node key.
  nodeKey.to(NibblesSeq).hexaryPath(rootKey, db)

proc hexaryPath*(
    nodeTag: NodeTag;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a node tag.
  nodeTag.to(NodeKey).hexaryPath(rootKey, db)

proc hexaryPath*(
    partialPath: Blob;
    rootKey: NodeKey|RepairKey;
    db: HexaryTreeDbRef;
      ): RPath
      {.gcsafe, raises: [CatchableError]} =
  ## Variant of `hexaryPath` for a  hex encoded partial path.
  partialPath.hexPrefixDecode[1].hexaryPath(rootKey, db)


proc hexaryPath*(
    partialPath: NibblesSeq;        # partial path to resolve
    rootKey: NodeKey;               # State root
    getFn: HexaryGetFn;             # Database abstraction
      ): XPath
      {.gcsafe, raises: [CatchableError]} =
  ## Compute the longest possible path on an arbitrary hexary trie.
  XPath(root: rootKey, tail: partialPath).rootPathExtend(getFn)

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
      {.gcsafe, raises: [CatchableError]} =
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
      {.gcsafe, raises: [CatchableError]} =
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
      {.gcsafe, raises: [CatchableError]} =
  ## Convert a list of path segments to a set of node keys
  partialPaths.toSeq
    .mapIt(it.hexaryPathNodeKey(rootKey, db, missingOk))
    .filterIt(it.isOk)
    .mapIt(it.value)
    .toHashSet

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
