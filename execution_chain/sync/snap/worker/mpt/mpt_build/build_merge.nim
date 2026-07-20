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
  std/[typetraits],
  pkg/[eth/common, eth/trie/nibbles],
  ../../../../wire_protocol/snap/snap_types,
  ./build_desc

# ------------------------------------------------------------------------------
# Private RLP helper
# ------------------------------------------------------------------------------

func encodeAccount(acc: AccBody): seq[byte] =
  ## Encode with `Account` type mode rather than `AccBody` packed
  ## transport mode used with `snap`.
  var w = initRlpWriter()
  w.startList 4
  w.append acc.nonce
  w.append acc.balance
  w.append acc.storageRoot.Hash32
  w.append acc.codeHash.Hash32
  w.finish()

template encodeAccount(acc: Account): seq[byte] =
  rlp.encode acc

# ------------------------------------------------------------------------------
# Private functions: non-recursive merge helpers
# ------------------------------------------------------------------------------

{.push checks: off, optimization: speed, raises: [].}

proc findSubTree(
    db: NodeTrieRef;
    path: Hash32;
      ): Result[(StopNodeRef,NibblesBuf),NibblesBuf] =
  ## Find the start of a sub-tree relative to the `path` argument. If a leaf
  ## node is encountered, it will be marked `mergedOk` and an a `nil` leaf
  ## node will be returned.
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
    parent = NodeBaseRef(nil)
    inx = 0u8
    node = NodeBaseRef(tree)
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
      var leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx.slice(n+1))
      branch.brLinks[pfx[n]] = leaf
      return ok(move leaf)

    of Stop:
      let w = StopNodeRef(node)
      if w.sub.isNil:
        var leaf = LeafNodeRef(kind: Leaf, lfPfx: pfx)
        w.sub = leaf
        return ok(move leaf)

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

  db.leafs.add (path, leaf)
  ok(leaf)

{.pop.}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc merge*(db: NodeTrieRef, acc: SnapAccount): Opt[void] =
  ## Merge the account leaf argument `acc` into a matching sub-MPT of the
  ## argument MPT `db`. The sub-MPT will not be keyed yet. This must be done
  ## as a finalisation step when all account leafs have been merged (see
  ## `finalise()`.)
  ##
  ## The function returns `true` if the account `acc` could be merged.
  ##
  let leaf = ?db.makeOrGetLeaf(acc.accHash)
  if not leaf.isNil:
    leaf.lfPayload = acc.accBody.encodeAccount()
  ok()

proc merge*(db: NodeTrieRef, accPath: Hash32, data: Account): Opt[void] =
  ## Variant of previous `merge()`
  ##
  let leaf = ?db.makeOrGetLeaf(accPath)
  if not leaf.isNil:
    leaf.lfPayload = data.encodeAccount()
  ok()

proc merge*(db: NodeTrieRef, sto: StorageItem): Opt[void] =
  ## Ditto for storage slots.
  ##
  let leaf = ?db.makeOrGetLeaf(sto.slotHash)
  if not leaf.isNil:
    leaf.lfPayload = sto.slotData
  ok()

proc merge*(db: NodeTrieRef, key: Hash32, data: UInt256): Opt[void] =
  ## Another variant for storage slots.
  ##
  let leaf = ?db.makeOrGetLeaf(key)
  if not leaf.isNil:
    leaf.lfPayload = rlp.encode(data)
  ok()

proc merge*(db: NodeTrieRef, key, pyl: openArray[byte]): Opt[void] =
  ## Variant of `merge()` for generic `key` and `payload` leaf argument for
  ## a generic trie which was initialised via `NodeTrieRef.init(root)`
  ## without proof data.
  ##
  ## This function is provided mainly for testing.
  ##
  if db.root.kind == Stop:
    let tree = StopNodeRef(db.root)
    if 2*key.len + tree.path.len == 64:
      tree.mergeSubTree(NibblesBuf.fromBytes key).isErrOr:
        value.lfPayload = @pyl
        return ok()
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
