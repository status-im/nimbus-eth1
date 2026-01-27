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
  std/[sequtils, tables, typetraits],
  pkg/[eth/common, stew/byteutils],
  ./mpt_desc

# ------------------------------------------------------------------------------
# Private RLP helpers
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter, val: AccBody) =
  ## Mixin, store with `Account` type encoding (rather than `AccBody` transport
  ## encoding from `snap`.)
  w.startList 4
  w.append val.nonce
  w.append val.balance
  w.append val.storageRoot.Hash32
  w.append val.codeHash.Hash32

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func high(T: type Hash32): T = high(UInt256).to(Bytes32).T

func `<`(a, b: Hash32): bool = a.distinctBase < b.distinctBase
func `<=`(a, b: Hash32): bool = not (b < a)

# ------------------------------------------------------------------------------
# Private functions: constructor helpers
# ------------------------------------------------------------------------------

proc nodeStash*(
    db: NodeTrieRef;                       # Needed for root node
    rootKey: NodeKey;                      # State root key
    proofNode: ProofNode;                  # Node to add
    nodes: var Table[NodeKey,NodeRef];     # Collect nodes
    links: var Table[NodeKey,StopNodeRef]; # Collect open links
      ): bool =
  ## Decode a trusted rlp-encoded node and add it to the node list.
  ##
  var selfKey = proofNode.digestTo(NodeKey)
  if selfKey.len < 32:
    let forcedKey = proofNode.digestTo(NodeKey, force32=true)
    if forcedKey == rootKey:
      selfKey = forcedKey

  # Already listed?
  if nodes.hasKey selfKey:
    return true

  var
    rlp = proofNode.distinctBase.rlpFromBytes
    list: array[17,seq[byte]]              # list of node entries
    top = 0                                # count entries, i.e. `list[]` len
    node: NodeRef

  # Collect lists of either 2 or 17 blob entries.
  try:
    for w in rlp.items:
      case top
      of 0 .. 15:
        list[top] = rlp.read(seq[byte])
      of 16:
        if 0 < rlp.read(seq[byte]).len:
          return false
      else:
        return false
      top.inc
  except RlpError:
    return false

  # Assemble node records
  case top
  of 2:
    if list[0].len == 0:
      return false
    let (isLeaf, nibbles) = NibblesBuf.fromHexPrefix list[0]
    if nibbles.len == 0:
      return false
    if isLeaf:
      node = LeafNodeRef(
        kind:      Leaf,
        lfData:    proofNode.distinctBase,
        lfPfx:     nibbles,
        lfPayload: list[1])
    else:
      let stopKey = list[1].to(NodeKey)
      if links.hasKey stopKey:
        return false
      node = BranchNodeRef(
        kind:    Branch,
        xtData:  proofNode.distinctBase,
        xtPfx:   nibbles)
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
    for n in 0u8 .. 15u8:
      if 0 < list[n].len:
        let stopKey = list[n].to(NodeKey)
        if links.hasKey stopKey:
          return false
        let stopLink = StopNodeRef(
          kind:    Stop,
          selfKey: stopKey,
          parent:  node,
          inx:     n)
        links[stopKey] = stopLink
        BranchNodeRef(node).brLinks[n] = stopLink
  else:
    return false

  if selfKey == rootKey:
    db.root = node

  node.selfKey = selfKey
  nodes[selfKey] = node
  true

proc updateProofTree(
    node: NodeRef;                         # Current node, start node
    path: NibblesBuf;                      # Current path, recursively updated
    last: var Hash32;                      # Path of last leaf, visited
      ) =
  ## Recursively label path prefixes, resolve extensions, and return the
  ## right boundary leaf path (if any).
  ##
  case node.kind:
  of Branch:
    let w = BranchNodeRef(node)
    if 0 < w.xtPfx.len:
      # Join child node into this extension node
      let chld = w.brLinks[0]
      if chld.kind == Branch and BranchNodeRef(chld).xtPfx.len == 0:
        w.brLinks = BranchNodeRef(chld).brLinks
        w.brData = BranchNodeRef(chld).brData
        w.brKey = BranchNodeRef(chld).brKey

    let path = path & w.xtPfx
    for n in 0 .. 15:
      let down = w.brLinks[n]
      if not down.isNil:
        if down.kind == Stop:
          # Might be dangling now due to the extension merge, above
          StopNodeRef(down).parent = w
        down.updateProofTree(path & NibblesBuf.nibble(byte n), last)

  of Leaf:
    last = getBytes(path & LeafNodeRef(node).lfPfx).to(Hash32)

  of Stop:
    StopNodeRef(node).path = path

# ------------------------------------------------------------------------------
# Private functions: merge helpers
# ------------------------------------------------------------------------------

proc findSubTree(
    db: NodeTrieRef;
    path: Hash32;
      ): Result[(StopNodeRef,NibblesBuf),NibblesBuf] =
  ## Find the start of a sub-tree relative to the `path` argument.
  ##
  var
    node = db.root
    pfx = NibblesBuf.fromBytes(path.data)

  while true:
    case node.kind:
    of Branch:
      if pfx.len == 0:
        return err(pfx)

      let w = BranchNodeRef(node)
      if 0 < w.xtPfx.len:
        let n = pfx.sharedPrefixLen(w.xtPfx)
        if n < w.xtPfx.len or                   # must be all of the ext pfx
           n == pfx.len:                        # must *not* be the last node
          return err(pfx)
        pfx = pfx.slice(n)

      node = w.brLinks[pfx[0]]
      if node.isNil:
        return err(pfx)
      pfx = pfx.slice(1)
      # continue

    of Leaf:
      let w = LeafNodeRef(node)
      if w.lfPfx != pfx:
        return err(pfx)
      return ok((nil,NibblesBuf()))

    of Stop:
      return ok((StopNodeRef(node),pfx))

  # NOTREACHED

proc mergeSubTree(
    tree: StopNodeRef;
    pfx: NibblesBuf;
      ): Result[LeafNodeRef,NibblesBuf] =
  ## Merge a `Leaf` node with an MPT path `pfx` into the sub-tree
  ##
  var
    parent = NodeRef(nil)
    inx = 0u8
    node = NodeRef(tree)
    pfx = pfx

  doAssert tree.path.len + pfx.len == 64

  while true:
    case node.kind:
    of Branch:
      let
        w = BranchNodeRef(node)
        n = pfx.sharedPrefixLen(w.xtPfx)
      doAssert n < pfx.len                        # at least pfx + nibble

      let i = pfx[n]
      if n < w.xtPfx.len:
        # parent->Branch0 => parent~>Branch1(new)->(Leaf(new),Branch0(mod))
        let branch = BranchNodeRef(kind: Branch, xtPfx: w.xtPfx.slice(0,n))
        if parent.kind == Branch:
          BranchNodeRef(parent).brLinks[inx] = branch
        else:
          StopNodeRef(parent).sub = branch

        # Note: n < w.xtPfx.len  =>  0 < w.xtPfx.len (because n is non-negaive)
        branch.brLinks[w.xtPfx[n]] = w
        w.xtPfx = w.xtPfx.slice(n+1)

        let leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx.slice(n+1))
        branch.brLinks[i] = leaf
        return ok(leaf)

      # So `n` == `w.xtPfx.len`
      if w.brLinks[i].isNil:
        # parent->Branch0 => parent~>Branch0(mod)->(Leaf(new),..)
        let leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx.slice(n+1))
        w.brLinks[i] = leaf
        return ok(leaf)

      # Try again with `node` as parent
      (parent,inx,node,pfx) = (w, i, w.brLinks[i], pfx.slice(n+1))
      # continue

    of Leaf:
      let w = LeafNodeRef(node)
      if w.lfPfx == pfx:                          # leaf node merged, already
        return ok(w)
      doAssert w.lfPfx.len == pfx.len             # due to fixed path length 64

      # parent->Leaf0 => parent->Branch(new)->(Leaf1(new),Leaf0(mod),..)
      let
        n = pfx.sharedPrefixLen(w.lfPfx)
        branch = BranchNodeRef(kind: Branch)

      # Insert new branch beween parent and current node
      branch.brLinks[w.lfPfx[n]] = w
      w.lfPfx = w.lfPfx.slice(n+1)
      if parent.kind == Branch:
        BranchNodeRef(parent).brLinks[inx] = branch
      else:
        StopNodeRef(parent).sub = branch

      # Add common prefix (n might be 0 ok)
      branch.xtPfx = pfx.slice(0, n)

      # Link leaf into new branch, parallel to the current node
      let leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx.slice(n+1))
      branch.brLinks[pfx[n]] = leaf
      return ok(leaf)

    of Stop:
      let w = StopNodeRef(node)
      if w.sub.isNil:
        let leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx)
        w.sub = leaf
        return ok(leaf)

      (parent,node) = (w, w.sub)
      # continue

  # NOTREACHED

# ------------------------------------------------------------------------------
# Private functions, finalisation and export helpers
# ------------------------------------------------------------------------------

proc reKeyWalker(
    node: NodeRef;
      ) =
  ## Recursively calculate rlp-data and node keys.
  ##
  case node.kind:
  of Branch:
    let br = BranchNodeRef(node)

    var wrt = initRlpList 17
    for n in 0 .. 15:
      if br.brLinks[n].isNil:
        wrt.append ""
      else:
        # Note that the recursion is exhaustive as the sub-tree
        # is always a complete MPT (i.e. no dead links)
        br.brLinks[n].reKeyWalker()
        wrt.append br.brLinks[n].selfKey.to(seq[byte])
    wrt.append ""
    br.brData = wrt.finish()
    br.selfKey = br.brData.digestTo(NodeKey)

    if 0 < br.xtPfx.len:
      br.selfKey.swap br.brKey
      wrt = initRlpList 2
      wrt.append br.xtPfx.toHexPrefix(false).toSeq
      wrt.append br.brKey.to(seq[byte])
      br.xtData = wrt.finish()
      br.selfKey = br.xtData.digestTo(NodeKey)

  of Leaf:
    let lf = LeafNodeRef(node)
    var wrt = initRlpList 2
    wrt.append lf.lfPfx.toHexPrefix(true).toSeq
    wrt.append lf.lfPayload
    lf.lfData = wrt.finish()
    lf.selfKey = lf.lfData.digestTo(NodeKey)

  of Stop:
    let w = StopNodeRef(node)
    if not w.sub.isNil:
      w.sub.reKeyWalker()

  # NOTREACHED

proc exportTrie(
    node: NodeRef;
    data: var seq[(NodeKey,seq[byte])];
    ok: var bool;
      ) =
  ## Recursively export rlp encodings
  ##
  case node.kind:
  of Branch:
    var w = BranchNodeRef(node)
    if w.brData.len == 0:
      ok = false
      return

    if 0 < w.xtPfx.len:
      if w.xtData.len == 0:
        ok = false
        return
      data.add (w.selfKey, w.xtData)
      data.add (w.brKey, w.brData)
    else:
      data.add (w.selfKey, w.brData)

    for n in 0 .. 15:
      if not w.brLinks[n].isNil:
        w.brLinks[n].exportTrie(data, ok)
        if not ok:
          return

  of Leaf:
    var w = LeafNodeRef(node)
    if w.lfData.len == 0:
      ok = false
      return
    data.add (w.selfKey, w.lfData)

  of Stop:
    ok = false

  # NOTREACHED

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type NodeTrieRef;
    stateRoot: StateRoot;
      ): T =
  ## Create an empty MPT.
  let db = T()
  db.root = StopNodeRef(
    kind:    Stop,
    selfKey: stateRoot.to(NodeKey))
  db.stops[db.root.selfKey] = StopNodeRef(db.root)
  db

proc init*(
    T: type NodeTrieRef;
    stateRoot: StateRoot;
    start: Hash32;
    nodes: openArray[ProofNode];
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
    return NodeTrieRef.init stateRoot

  let
    db = T()
    root = stateRoot.to(NodeKey)
  var
    tmpNodes: Table[NodeKey,NodeRef]
    tmpLinks: Table[NodeKey,StopNodeRef]
  for n in 0 ..< nodes.len:
    if not db.nodeStash(root, nodes[n], tmpNodes, tmpLinks):
      return T(nil)

  # Verify that there is a root from stashed data
  if db.root.isNil:
    return T(nil)

  # Root is not needed in the list, anymore
  tmpNodes.del db.root.selfKey

  # Build partial tree
  let stopPairs = tmpLinks.pairs.toSeq
  for (stopKey,stopNode) in stopPairs:
    # Try to resolve the stop node on a `node` table entry
    tmpNodes.withValue(stopKey, node):
      let parent = stopNode.parent
      BranchNodeRef(parent).brLinks[stopNode.inx] = node[]
      tmpLinks.del stopKey

  # Label path prefixes and join Extensions
  var limit = high(Hash32)
  db.root.updateProofTree(NibblesBuf(), limit)

  # Select sub-roots, links within min/max bounds
  for (key,stopNode) in tmpLinks.pairs:
    let path = stopNode.path.getBytes.to(Hash32)
    if start <= path and path < limit:
      db.stops[key] = stopNode
    else:
      # Remove stop node from parent
      BranchNodeRef(stopNode.parent).brLinks[stopNode.inx] = nil

  db

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(db: NodeTrieRef, acc: SnapAccount): bool =
  ## Merge the account leaf argument `acc` into a matching sub-trie of the
  ## argument MPT `db`. The sub-trie will not be keyed yet. This must be done
  ## as a finalisation step when all account leafs have been merged (see
  ## `finalise()`.)
  ##
  ## The function returns `true` if the account `acc` could be merged.
  ##
  # Find sub-tree
  let (tree,pfx) = db.findSubTree(acc.accHash).valueOr:
    return false

  if pfx.len == 0:
    return true

  # Merge/append
  let leaf = tree.mergeSubTree(pfx).valueOr:
    return false

  # Update leaf record payload
  leaf.lfPayload = rlp.encode(acc.accBody)
  true

proc finalise*(db: NodeTrieRef): uint =
  ## Finalise an MPT.
  ##
  ## Recusively calculate missing node keys and merge complete sub-tries
  ## into the already locked and finished part of the MPT.
  ##
  ## The function returns the number of sub-tries resolved (see also
  ## function `isComplete()`.
  ##
  ## Note: This function can savely be called any time while merging (see
  ##  `merge()`) is still ongoing. It is only inefficient because
  ##   non-finalised sub-tyries need to be visited, again.
  ##
  var resolved: seq[NodeKey]
  for (key,stopNode) in db.stops.pairs:

    if not stopNode.sub.isNil:
      stopNode.reKeyWalker()

      if stopNode.sub.selfKey == stopNode.selfKey:
        # Join with pre-set part, this locks this sub-tree
        if stopNode.parent.isNil:
          db.root = stopNode.sub
        else:
          BranchNodeRef(stopNode.parent).brLinks[stopNode.inx] = stopNode.sub
        resolved.add key

  result = resolved.len.uint
  if db.stops.len.uint <= result:
    db.stops.clear
  else:
    for key in resolved:
      db.stops.del key

proc isComplete*(db: NodeTrieRef): bool =
  ## Check whether the MPT is complete.
  ##
  not db.root.isNil and db.stops.len == 0

# -----------

proc validate*(
    root: StateRoot;
    start: Hash32;
    pck: AccountRangePacket;
      ): Opt[NodeTrieRef] =
  ## Validate snap account data package.
  ##
  let db = NodeTrieRef.init(root, start, pck.proof)
  if not db.isNil:
    for acc in pck.accounts:
      if not db.merge(acc):
        return err()

    discard db.finalise()
    if db.isComplete():
      return ok(db)
  err()

proc pairs*(db: NodeTrieRef): seq[(NodeKey,seq[byte])] =
  ## Export partial MPT. If an error occurs, no data is exported.
  ##
  if db.isComplete():
    var (ok, data) = (true, seq[(NodeKey,seq[byte])].default)
    db.root.exportTrie(data, ok)
    if ok:
      return data

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
