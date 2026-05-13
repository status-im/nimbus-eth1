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
  pkg/[eth/common, eth/trie/nibbles, stew/byteutils],
  ../../../wire_protocol/snap/snap_types,
  ../state_db,
  ./mpt_desc

const
  ffffHash = high(ItemKey).to(Hash32)

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

proc decodeByteList(rawData: openArray[byte]): Opt[seq[byte]] =
  try:
    var rlp = rawData.rlpFromBytes
    return ok rlp.read seq[byte]
  except RlpError:
    discard
  err()

proc decodeHashKey(rawData: openArray[byte]): Opt[HashKey] =
  var key: HashKey
  if rawData.len < 32:
    key = HashKey.fromBytes(rawData).valueOr:
      return err()
  else:
    let keyData = rawData.decodeByteList().valueOr:
      return err()
    key = HashKey.fromBytes(keyData).valueOr:
      return err()
  ok(move key)

# ------------------------------------------------------------------------------
# Private functions: constructor helpers
# ------------------------------------------------------------------------------

proc nodeStash*(
    db: NodeTrieRef;                                # Needed for root node
    rootKey: HashKey;                               # State root key
    proofNode: ProofNode;                           # Node to add
    nodes: var Table[HashKey,NodeRef];              # Collect nodes
    links: var Table[HashKey,StopNodeRef];          # Collect open links
      ): bool =
  ## Decode a trusted rlp-encoded node and add it to the node list.
  ##
  var selfKey = proofNode.digestTo(HashKey)
  if selfKey.len < 32:
    let forcedKey = proofNode.digestTo(HashKey, force32=true)
    if forcedKey == rootKey:
      selfKey = forcedKey

  # Already listed?
  if nodes.hasKey selfKey:
    return true

  var
    rlp = proofNode.distinctBase.rlpFromBytes
    list: array[17,seq[byte]]                       # list of node entries
    top = 0                                         # count `list[]` entries
    node: NodeRef

  # Collect lists of either 2 or 17 blob entries.
  try:
    for w in rlp.items:
      case top
      of 0 .. 15:
        if not w.isEmpty:
          list[top] = @(w.rawData)
      of 16:
        if not w.isEmpty:
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
    let
      path = list[0].decodeByteList().valueOr:
        return false
      (isLeaf, nibbles) = NibblesBuf.fromHexPrefix path
    if isLeaf:
      node = LeafNodeRef(
        kind:      Leaf,
        lfData:    proofNode.distinctBase,
        lfPfx:     nibbles,
        lfPayload: list[1])
    elif nibbles.len == 0:
      return false
    else:
      let stopKey = list[1].decodeHashKey().valueOr:
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
        let stopKey = list[n].decodeHashKey().valueOr:
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
    node: NodeRef;                                  # current node, start node
    path: NibblesBuf;                               # cur path, recurs. updated
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
      if chld.kind == Stop:                         # pure extension node?
        StopNodeRef(chld).parent = w                # just to make sure
        chld.updateProofTree(path & w.xtPfx)
        return
      if chld.kind == Branch and BranchNodeRef(chld).xtPfx.len == 0:
        w.brLinks = BranchNodeRef(chld).brLinks
        w.brData = BranchNodeRef(chld).brData
        w.brKey = BranchNodeRef(chld).selfKey

    let path = path & w.xtPfx
    for n in 0 .. 15:
      let down = w.brLinks[n]
      if not down.isNil:
        if down.kind == Stop:
          # Might be dangling now due to the extension merge, above
          StopNodeRef(down).parent = w
        down.updateProofTree(path & NibblesBuf.nibble(byte n))

  of Leaf:
    discard

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
      block extOrCombined:
        if 0 < w.xtPfx.len:                         # ext. or combined branch
          let n = pfx.sharedPrefixLen(w.xtPfx)
          if n < w.xtPfx.len or                     # must be all of the ext pfx
             n == pfx.len:                          # must NOT be the last node
            return err(pfx)

          pfx = pfx.slice(n)                        # cut off `xtPfx`
          if w.brData.len == 0:                     # `0` => pure extension
            node = w.brLinks[0]                     # extension on index `0`
            break extOrCombined

        node = w.brLinks[pfx[0]]                    # otherwise use nibble
        pfx = pfx.slice(1)

      if node.isNil:
        return err(pfx)
      # continue

    of Leaf:
      let w = LeafNodeRef(node)
      if w.lfPfx != pfx:
        return err(pfx)
      return ok((nil,EmptyPath))

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
      doAssert n < pfx.len                          # at least pfx + nibble

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
      if w.lfPfx == pfx:                            # leaf node merged, already
        return ok(w)
      doAssert w.lfPfx.len == pfx.len               # due to fixed path len 64

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

proc makeOrGetLeaf(db: NodeTrieRef; path: Hash32): Opt[LeafNodeRef] =
  ## Unless done jet, make a leaf on the tree with the argument path `path`.
  ##
  # Find sub-tree
  let (tree,pfx) = db.findSubTree(path).valueOr:
    return err()

  if pfx.len == 0:
    return ok(LeafNodeRef nil)

  let leaf = tree.mergeSubTree(pfx).valueOr:
    return err()

  ok(leaf)

# ------------------------------------------------------------------------------
# Private functions, finalisation and export helpers
# ------------------------------------------------------------------------------

proc reKeyWalker(node: NodeRef) =
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
        wrt.append br.brLinks[n].selfKey
    wrt.append ""
    br.brData = wrt.finish()
    br.selfKey = br.brData.digestTo(HashKey)

    if 0 < br.xtPfx.len:
      br.selfKey.swap br.brKey
      wrt = initRlpList 2
      wrt.append br.xtPfx.toHexPrefix(false).toSeq
      wrt.append br.brKey
      br.xtData = wrt.finish()
      br.selfKey = br.xtData.digestTo(HashKey)

  of Leaf:
    let lf = LeafNodeRef(node)
    var wrt = initRlpList 2
    wrt.append lf.lfPfx.toHexPrefix(true).toSeq
    wrt.append lf.lfPayload
    lf.lfData = wrt.finish()
    lf.selfKey = lf.lfData.digestTo(HashKey)

  of Stop:
    let w = StopNodeRef(node)
    if not w.sub.isNil:
      w.sub.reKeyWalker()

proc exportTrie(
    node: NodeRef;
    data: var seq[(seq[byte],seq[byte])];
    ok: var bool;
      ) =
  ## Recursively export rlp encodings
  ##
  case node.kind:
  of Branch:
    var w = BranchNodeRef(node)
    if w.brData.len == 0:
      if 0 < w.xtData.len and
         not w.brLinks[0].isNil:                    # pure extension node
        data.add (@(w.selfKey.data), w.xtData)
        w.brLinks[0].exportTrie(data, ok)
      else:
        ok = false                                  # error
      return

    if 0 < w.xtPfx.len:
      if w.xtData.len == 0:
        ok = false
        return
      data.add (@(w.selfKey.data), w.xtData)
      data.add (@(w.brKey.data), w.brData)
    else:
      data.add (@(w.selfKey.data), w.brData)

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
    data.add (@(w.selfKey.data), w.lfData)

  of Stop:
    ok = false

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type NodeTrieRef;
    root: StateRoot|StoreRoot;
      ): T =
  ## Create an empty MPT.
  let db = T()
  db.root = StopNodeRef(
    kind:    Stop,
    selfKey: root.to(HashKey))
  db.stops[db.root.selfKey] = StopNodeRef(db.root)
  db

proc init*(
    T: type NodeTrieRef;
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
    tmpNodes: Table[HashKey,NodeRef]
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
      tmpLinks.del stopKey

  # Label path prefixes and join Extensions
  db.root.updateProofTree(EmptyPath)

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

  db

proc init*(
    T: type NodeTrieRef;
    root: Hash32;
    nodes: seq[seq[byte]];
    keyBytes = 32;
      ): T =
  ## Create a generic MPT.
  ##
  ## The `nodes` argument is a list of rlp encoded nodes, just as with
  ## the list of proof nodes with the previous verions of `init()`.
  ##
  ## The argument `keyBytes` allows for a trie where all
  ## keys have a length smaller than 32 bytes.
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

  var tmpNodes: Table[HashKey,NodeRef]
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
      db.stops.del stopKey

  # Label path prefixes and join Extensions
  db.root.updateProofTree(EmptyPath)
  db

proc init*(
    T: type NodeTrieRef;
    root: Hash32;
    keyBytes = 32;
      ): T =
  ## Shortcut for `NodeTrieRef.init(root,@[],keyBytes)`
  NodeTrieRef.init(root,seq[seq[byte]].default,keyBytes)

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
  let leaf = db.makeOrGetLeaf(acc.accHash).valueOr:
    return false
  if not leaf.isNil:
    leaf.lfPayload = rlp.encode(acc.accBody)
  true

proc merge*(db: NodeTrieRef, sto: StorageItem): bool =
  ## Ditto for storage slots.
  ##
  let leaf = db.makeOrGetLeaf(sto.slotHash).valueOr:
    return false
  if not leaf.isNil:
    leaf.lfPayload = sto.slotData
  true

proc merge*(db: NodeTrieRef, key: openArray[byte], pyl: openArray[byte]): bool =
  ## Variant of `merge()` for generic `key` and `payload` leaf argument for
  ## a generic trie which was initialised via `NodeTrieRef.init(root)`
  ## without proof data.
  ##
  ## This function is provided mainly for testing.
  ##
  if db.root.kind == Stop:
    let tree = StopNodeRef(db.root)
    if 2*key.len + tree.path.len == 64:
      let
        pfx = NibblesBuf.fromBytes(key)
        leaf = tree.mergeSubTree(pfx).valueOr:
          return false

      leaf.lfPayload = @pyl
      return true
  # false

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
  var resolved: seq[HashKey]
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

proc validate*[T: SnapAccount|StorageItem](
    root: StateRoot|StoreRoot;
    start: ItemKey;
    leafs: openArray[T];
    proof: openArray[ProofNode]
      ): Opt[NodeTrieRef] =
  ## Validate snap accounts or storage slot data package.
  ##
  when root is StateRoot and T isnot SnapAccount:
    {.error: "Leafs item must be of type SnapAccount for root type StateRoot".}
  elif root is StoreRoot and T isnot StorageItem:
    {.error: "Leafs item must be of type StorageItem for root type StoreRoot".}

  var limit = ffffHash
  if 0 < leafs.len:
    when T is SnapAccount:
      limit = leafs[^1].accHash
    elif T is StorageItem:
      limit = leafs[^1].slotHash
    else:
      {.error: "Unexpedted type for leafs[]".}      # `T` type was extended?

  let db = NodeTrieRef.init(root, start, proof, limit)
  if not db.isNil:
    for leaf in leafs:
      if not db.merge(leaf):
        return err()

    discard db.finalise()
    if db.isComplete():
      return ok(db)
  err()

proc kvPairs*(db: NodeTrieRef): seq[(seq[byte],seq[byte])] =
  ## Export partial MPT. If an error occurs, no data is exported.
  ##
  if db.isComplete():
    var (ok, data) = (true, seq[(seq[byte],seq[byte])].default)
    db.root.exportTrie(data, ok)
    if ok:
      return data
  # @[]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
