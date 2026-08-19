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
  std/[sequtils, tables],
  pkg/eth/trie/nibbles,
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ./build_desc

# ------------------------------------------------------------------------------
# Private functions, recursive finalisation and export helpers
# ------------------------------------------------------------------------------

{.push checks: off, optimization: speed, raises: [].}

template exportTrieLeaf(node: LeafNodeRef, queue: seq[KnPair]): bool =
  let ok =
    if node.lfData.len == 0:
      false
    else:
      queue.add (@(node.selfKey.data), node.lfData)
      true
  ok

proc exportTrieBranch(node: BranchNodeRef, queue: var seq[KnPair]): bool =
  ## Recursively export rlp encodings
  ##
  if node.brData.len == 0:                          # pure extenson node?
    let link = node.brLinks[0]
    if node.xtData.len == 0 or link.isNil:          # check validity
      return false                                  # oops => error
    queue.add (@(node.selfKey.data), node.xtData)   # add extension `(key,node)`
    if link.kind == Branch:
      if BranchNodeRef(link).exportTrieBranch(queue):
        return true
    else:
      if LeafNodeRef(link).exportTrieLeaf(queue):
        return true
    return false

  if 0 < node.xtPfx.len:                            # combined ext/branch node?
    if node.xtData.len == 0:                        # check validity
      return false                                  # oops => error
    queue.add (@(node.selfKey.data), node.xtData)   # add extension `(key,node)`
    queue.add (@(node.brKey.data), node.brData)     # add branch `(key,node)`

  else:
    queue.add (@(node.selfKey.data), node.brData)   # only branch `(key,node)`

  for n in 0 .. 15:                                 # export linked sub-MPTs
    let link = node.brLinks[n]
    if not link.isNil:
      if link.kind == Branch:
        if BranchNodeRef(link).exportTrieBranch(queue):
          continue
      else:
        if LeafNodeRef(link).exportTrieLeaf(queue):
          continue
      return false
  true

template exportTrie(node: NodeBaseRef, queue: var seq[KnPair]): bool =
  ## Recursively export rlp encodings
  let ok =
    if node.kind == Branch: BranchNodeRef(node).exportTrieBranch(queue)
    else: LeafNodeRef(node).exportTrieLeaf(queue)
  ok

{.pop.}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isComplete*(db: NodeTrieRef): bool =
  ## Check whether the MPT is complete and ready for export.
  ##
  not db.root.isNil and db.stops.len == 0

proc knPairs*(db: NodeTrieRef): seq[KnPair] =
  ## Export partial MPT. If an error occurs, no data is exported.
  ##
  if db.isComplete():
    var data = seq[KnPair].default
    if db.root.exportTrie(data):
      return data
  # @[]

proc danglingKp*(db: NodeTrieRef): seq[KpPair] =
  ## Returns a list of pairs `(key,path)` of the dangling links.
  ##
  db.dangling.mapIt((@(it[0].data),@(it[1].path.toHexPrefix(false).data())))

proc leafKpp*(db: NodeTrieRef): seq[KppTriple] =
  ## Returns the pairs `(key,path,payload)` for the leaf nodes from the
  ## `proof` list if they are not contained in the merged leafs, as well.
  ##
  db.leafs.mapIt((@(it[1].selfKey.data), it[0], it[1].lfPayload))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
