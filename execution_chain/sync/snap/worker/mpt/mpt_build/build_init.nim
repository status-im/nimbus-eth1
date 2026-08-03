# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[sequtils, strutils, tables, typetraits],
  pkg/[eth/trie/nibbles, stew/byteutils],
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ./build_desc

# ------------------------------------------------------------------------------
# Private RLP helper
# ------------------------------------------------------------------------------

proc read(r: var Rlp, T: type HashKey): T {.gcsafe, raises: [RlpError]} =
  if r.isList:
    HashKey.fromBytes(r.rawData).value
  else:
    HashKey.fromBytes(r.toBytes).value

# ------------------------------------------------------------------------------
# Private functions: partial proof MPT constructor helpers
# ------------------------------------------------------------------------------

{.push checks: off, optimization: speed, raises: [].}

proc nodeStash(
    db: NodeTrieRef;                                # Needed for root node
    rootKey: HashKey;                               # State root key
    proofNode: ProofNode;                           # Node to add
    nodes: var Table[HashKey,NodeBaseRef];          # Collect nodes
    links: var Table[HashKey,StopNodeRef];          # Collect open links
      ): bool =
  ## Decode a trusted rlp-encoded node and add it to the node list.
  ##
  let selfKey = proofNode.digestToOrPlain(HashKey, rootKey)
  if nodes.hasKey selfKey:                          # Already seen and listed?
    return true

  var
    node: NodeBaseRef
    rlp = proofNode.distinctBase.rlpFromBytes()
  try:
    case rlp.listLen
    of 2:
      let (isLeaf, pfx) = NibblesBuf.fromHexPrefix rlp.listElem(0).toBytes
      var pyl = rlp.listElem(1)                     # Rlp type, payload or link
      if isLeaf:
        # Apparently, proof node account leaves are *not* in slim format
        # corresponding to an RLP encoded `AccBody` type object. Rather
        # they are assumed an `Account` type object. Otherwise the
        # `Hash32(proofNode)` would not result in something meaningful.
        node = LeafNodeRef(
          kind:      Leaf,
          lfData:    proofNode.distinctBase,
          lfPfx:     pfx,
          lfPayload: pyl.read seq[byte])

      elif pfx.len == 0:
        return false

      else:
        let stopKey = pyl.read HashKey
        node = BranchNodeRef(
          kind:    Branch,
          xtData:  proofNode.distinctBase,
          xtPfx:   pfx)
        let stopLink = StopNodeRef(
          kind:    Stop,
          selfKey: stopKey,
          parent:  node,
          inx:     0)
        links[stopKey] = stopLink
        BranchNodeRef(node).brLinks[0] = stopLink

    of 17:
      node = BranchNodeRef(
        kind:   Branch,
        brData: proofNode.distinctBase)
      var n = 0u8
      for w in rlp.items:
        if not w.isEmpty:
          let stopKey = w.read HashKey
          let stopLink = StopNodeRef(
            kind:    Stop,
            selfKey: stopKey,
            parent:  node,
            inx:     n)
          links[stopKey] = stopLink
          BranchNodeRef(node).brLinks[n] = stopLink
        n.inc

    else:
      return false
  except RlpError:
    return false

  if selfKey == rootKey:
    db.root = node
  node.selfKey = selfKey
  nodes[selfKey] = node
  true

# ---------------

proc updateProofTrieBranch(
    node: BranchNodeRef;
    path: NibblesBuf;
    leafs: var seq[(Hash32,LeafNodeRef)];
      ) =
  if 0 < node.xtPfx.len:
    # Join child node into this extension node
    let chld = node.brLinks[0]
    if chld.kind == Stop:                         # pure extension node?
      StopNodeRef(chld).parent = node             # just to make sure
      StopNodeRef(chld).path = path & node.xtPfx
      return
    if chld.kind == Branch and BranchNodeRef(chld).xtPfx.len == 0:
      node.brLinks = BranchNodeRef(chld).brLinks
      node.brData = BranchNodeRef(chld).brData
      node.brKey = BranchNodeRef(chld).selfKey

  let path = path & node.xtPfx
  for n in 0u8 .. 15u8:
    let down = node.brLinks[n]
    if not down.isNil:
      let path = path & NibblesBuf.nibble(n)
      case down.kind:
      of Stop:
        # Parent link might be dangling now due to the extension merge, above
        StopNodeRef(down).parent = node
        StopNodeRef(down).path = path
      of Branch:
        BranchNodeRef(down).updateProofTrieBranch(path, leafs)
      of Leaf:
        let down = LeafNodeRef(down)
        leafs.add (Hash32((path & down.lfPfx).getBytes), down)

template updateProofTrie(
    root: NodeBaseRef;
    leafs: var seq[(Hash32,LeafNodeRef)];
      ) =
  ## Recursively traverse partial proof MPT and label path prefixes so they
  ## are available on the `Stop` nodes. Also dissolve extensions inuo the
  ## child `Branch` node (if possible.)
  ##
  if root.kind == Branch:                           # includes extension node
    BranchNodeRef(root).updateProofTrieBranch(EmptyPath, leafs)
  # Otherwise there is nothing to do

{.pop.}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*[T: NodeTrieRef](
    _: type T;
    root: StateRoot|StoreRoot;
      ): T =
  ## Create an empty MPT.
  let db = T()
  db.root = StopNodeRef(
    kind:    Stop,
    selfKey: root.to(HashKey))
  db.stops[db.root.selfKey] = StopNodeRef(db.root)
  db

proc init*[T: NodeTrieRef](
    _: type T;
    root: StateRoot|StoreRoot;
    start: ItemKey;
    nodes: openArray[ProofNode];
    maxPath: Hash32;
      ): T =
  ## Create a partial MPT from a list of rlp encoded nodes. Some conditions
  ## on the argument list `nodes` are:
  ## * One of the `nodes` must be a root node.
  ## * If `nodes` is not empty, there must be two leaf nodes serving as
  ##   boundariies.
  ## Nodes from the argument list `nodes` which are not reachable from the
  ## root node are silently discarded.
  ##
  if nodes.len == 0:
    return NodeTrieRef.init root

  let
    db = T()
    root = root.to(HashKey)
  var
    tmpNodes: Table[HashKey,NodeBaseRef]
    tmpLinks: Table[HashKey,StopNodeRef]
  for n in 0 ..< nodes.len:
    if not db.nodeStash(root, nodes[n], tmpNodes, tmpLinks):
      return T(nil)

  # Verify that there is a root from stashed data
  if db.root.isNil:
    return T(nil)

  # Root is not needed in the list, anymore
  tmpNodes.del db.root.selfKey

  # Build partial tree
  let stopPairs = tmpLinks.pairs.toSeq              # table is to be modified
  for (stopKey,stopNode) in stopPairs:
    # Try to resolve the stop node on a `node` table entry
    tmpNodes.withValue(stopKey, node):
      let parent = stopNode.parent
      BranchNodeRef(parent).brLinks[stopNode.inx] = node[]
      tmpLinks.del stopKey                          # remove from sub-MPT list

  # Label path prefixes and join Extensions
  db.root.updateProofTrie db.leafs

  # Assemble right limit
  let limit = maxPath.to(ItemKey)

  # Select sub-roots, links within min/max bounds
  for (key,stopNode) in tmpLinks.pairs:
    let path = ItemKey.fromNibbles(stopNode.path, padMin)
    if start <= path and path <= limit:
      db.stops[key] = stopNode
    else:
      # Remove stop node from parent
      BranchNodeRef(stopNode.parent).brLinks[stopNode.inx] = nil
      db.dangling.add (key,stopNode)                # register dangling keys

  db

proc init*[T: NodeTrieRef](
    _: type T;
    root: Hash32;
    nodes: seq[seq[byte]];
    keyBytes = 32;
      ): T =
  ## Create a generic MPT.
  ##
  ## The `nodes` argument is a list of rlp encoded nodes, just as with
  ## the list of proof nodes with the previous verions of `init()`.
  ##
  ## The argument `keyBytes` allows for a partial MPT where all keys have
  ## a length smaller than 32 bytes.
  ##
  ## This function is provided mainly for testing.
  ##
  let
    db = T()
    root = root.to(HashKey)

  if nodes.len == 0:
    db.root = StopNodeRef(
      kind:    Stop,
      path:    NibblesBuf.fromBytes byte(0).repeat(max(0, 32 - keyBytes)),
      selfKey: root)
    db.stops[db.root.selfKey] = StopNodeRef(db.root)
    return db

  var tmpNodes: Table[HashKey,NodeBaseRef]
  for n in 0 ..< nodes.len:
    if not db.nodeStash(root, ProofNode(nodes[n]), tmpNodes, db.stops):
      return T(nil)

  # Verify that there is a root from stashed data
  if db.root.isNil:
    return T(nil)

  # Root is not needed in the list, anymore
  tmpNodes.del db.root.selfKey

  # Build partial tree
  let stopPairs = db.stops.pairs.toSeq              # table is to be modified
  for (stopKey,stopNode) in stopPairs:
    # Try to resolve the stop node on a `node` table entry
    tmpNodes.withValue(stopKey, node):
      let parent = stopNode.parent
      BranchNodeRef(parent).brLinks[stopNode.inx] = node[]
      db.stops.del stopKey                          # remove from sub-MPT list

  # Label path prefixes and join Extensions
  db.root.updateProofTrie db.leafs
  db

proc init*[T: NodeTrieRef](_: type T, root: Hash32, keyBytes = 32): T =
  ## Shortcut for `NodeTrieRef.init(root,@[],keyBytes)`
  T.init(root, seq[seq[byte]].default, keyBytes)

proc init*[T: NodeTrieRef](_: type T, keyBytes = 32): T =
  ## Shortcut for `NodeTrieRef.init(root,@[],keyBytes)`
  T.init(zeroHash32, seq[seq[byte]].default, keyBytes)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
