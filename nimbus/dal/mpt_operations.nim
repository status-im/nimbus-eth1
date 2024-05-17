#[  Nimbus
    Copyright (c) 2021-2024 Status Research & Development GmbH
    Licensed and distributed under either of
      * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
      * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
    at your option. This file may not be copied, modified, or distributed except according to those terms. ]#


##[ This module provides methods for adding and removing items from the tree. Intermediate Branch
    and Extension nodes are implicitly generated (or removed). Changes are always performed in the
    context of a `DiffLayer`, which can be stacked on top of previous diff layers, which remain
    immutable. Modifications can fail gracefuly in case a sub-tree is not loaded, such that it can
    be loaded and the operation resumed. ]##

import
  ./[mpt, mpt_nibbles]

export mpt, mpt_nibbles


const emptyBytesArray32: array[32, byte] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
const emptyBuffer32 = Buffer32(bytes: emptyBytesArray32, len: 0)

func toBuffer32*(arr: openArray[byte]): Buffer32 =
  result = emptyBuffer32
  result.bytes[0..<arr.len] = arr[0..^1]
  result.len = arr.len.uint8


func newLeaf(diffHeight: uint64, path: Nibbles64, value: Buffer32): MptLeaf =
  MptLeaf(
    diffHeight:   diffHeight,
    hashOrRlp:    emptyBuffer32,
    path:         path,
    value:        value)


func newAccount(diffHeight: uint64, path: Nibbles64, balance: UInt256,
    nonce: uint64, code: seq[byte], codeHash: ref array[32, byte]): MptAccount =
  MptAccount(
    diffHeight:   diffHeight,
    hashOrRlp:    emptyBuffer32,
    path:         path,
    balance:      balance,
    nonce:        nonce,
    code:         code,
    codeHash:     codeHash)


func newExtension(diffHeight: uint64, remainderPath: Nibbles, child: MptBranch): MptExtension =
  MptExtension(
    diffHeight:    diffHeight,
    hashOrRlp:     emptyBuffer32,
    remainderPath: remainderPath,
    child:         child)


func newBranch(diffHeight: uint64, children: array[16, MptNode]): MptBranch =
  MptBranch(
    diffHeight:   diffHeight,
    hashOrRlp:    emptyBuffer32,
    children:     children)


func newBranch(diffHeight: uint64): MptBranch =
  MptBranch(
    diffHeight:   diffHeight,
    hashOrRlp:    emptyBuffer32)


func stackDiffLayer*(base: DiffLayer): DiffLayer =
  ## Create a new diff layer, using an incremented diffHeight. Descendants will be cloned when
  ## they're on the path to a node being updated.
  result = DiffLayer(diffHeight: base.diffHeight + 1, root: base.root)



method put(node: MptNode, diffHeight: uint64, logicalDepth: uint8, key: Nibbles64, value: Buffer32):
    tuple[updatedNode: MptNode, missing: MptContinuation] {.base.} =
  doAssert false


#[
If the key matches the leaf's path:
  If the value matches the leaf's value, do nothing
  Else, if the diffHeight matches the leaf's diffHeight, update the value in-place
  Else, create a new leaf with the key, value, and diffHeight

If the key does not match the leaf's path and they diverge at the first nibble, return a new branch
with two leaves, e.g.:
__________________________________________________

   Input:       56789a     Leaf 1
__________________________________________________

   Input:    ...bcdef0     Key-Value
__________________________________________________

   Output:      |          Branch  (new)
                56789a     Leaf 1' (cloned leaf 1 with increased depth; hence different hash)
                bcdef0     Leaf 2  (new leaf with given key-value)
__________________________________________________

If the key does not match the leaf's path and they diverge mid-way, return a new extension node that
captures the common path and holds a new branch with two leaves, e.g.:
__________________________________________________

   Input:       56789a     Leaf 1
__________________________________________________

   Input:    ...56def0     Key-Value
__________________________________________________

   Output:      56         Extension (new)
                  |        Branch (new)
                  789a     Leaf 1' (cloned leaf 1 with increased depth; hence different hash)
                  def0     Leaf 2  (new leaf with given key-value)
__________________________________________________
]#
method put(leaf: MptLeaf, diffHeight: uint64, logicalDepth: uint8, key: Nibbles64, value: Buffer32):
    tuple[updatedNode: MptNode, missing: MptContinuation] =

  # Check if the key matches the (remainder of) the leaf path
  var divergence = logicalDepth
  while divergence < 64 and leaf.path[divergence] == key[divergence]:
    inc divergence

  # The key matches the leaf's path
  if divergence == 64:

    # The value matches the leaf's value; do nothing
    if leaf.value.len == value.len and leaf.value.bytes == value.bytes:
      return (leaf, nil)

    # The leaf belongs to the required diff; update it in-place
    elif leaf.diffHeight == diffHeight:
      leaf.value = value
      return (leaf, nil)

    # Clone the leaf and update its value
    else:
      let newLeaf = newLeaf(diffHeight, key, value)
      return (newLeaf, nil)

  # The paths differ
  else:
    # We create a branch to hold the existing leaf and a new leaf with the given ken-value. In case
    # the key and leaf path diverged after the first nibble, we also need to introduce an extension
    # node that captures the common path, and holds that branch.

    var children: array[16, MptNode]
    children[leaf.path[divergence]] = newLeaf(diffHeight, leaf.path, leaf.value)
    children[key[divergence]] = newLeaf(diffHeight, key, value)
    let branch = newBranch(diffHeight, children)

    if divergence == logicalDepth:
      return (branch, nil)

    else: # Need an extension
      let remainderPath = leaf.path.slice(logicalDepth, divergence - logicalDepth)
      let extension = newExtension(diffHeight, remainderPath, branch)
      return (extension, nil)


#[
If the extension node belongs to a different diff height, clone it.
If the key matches the extension's remainder path, call `put()` on the child branch, and update the
child branch.

CASE #1: the key does not match the extension path, and the extension path length is 1; replace the
extension by a branch, and add the key-value to it. Example:
__________________________________________________

   Input:       9     Extension 1
                 |    Branch 1
__________________________________________________

   Input:    ...b...  Key-Value
__________________________________________________

   Output:      |     Branch 2 (new)
                9|    Branch 1
                b...  Leaf (new)
__________________________________________________

CASE #2: the key does not match the extension path, and the extension path length is >1; we wrap the
extension with a branch and add the key-value to it. Example:
__________________________________________________

   Input:       56789a     Extension 1
                      |    Branch 1
__________________________________________________

   Input:    ...01bc...    Key-Value
__________________________________________________

   Output:      |          Branch 2 (new)
                56789a     Extension 2 (new)
                      |    Branch 1
                01bc...    Leaf (new)
__________________________________________________


CASE #3: If the key (e.g. `...56789b...`) matches the extension's remainder path (e.g. `56789a`)
except for the last nibble (e.g. `b` instead of `a`), we inject a new branch underneath the
extension that holds the previous branch along a new leaf for the given key-value. Example:
__________________________________________________

   Input:       56789a     Extension 1
                      |    Branch 1
__________________________________________________

   Input:    ...56789b...  Key-Value
__________________________________________________

   Output:      56789      Extension 2 (new)
                     |     Branch 2 (new)
                     a|    Branch 1
                     b...  Leaf (new)
__________________________________________________


CASE #4: If the key (e.g. `...56bc...`) partially matches the extension's remainder path (e.g.
`56789a`) such that two or more trailing nibbles differ, we inject both a branch (as described
above) and another extension. Example:
__________________________________________________

   Input:       56789a     Extension 1
                      |    Branch 1
__________________________________________________

   Input:    ...56bc...    Key-Value
__________________________________________________

   Output:      56         Extension 3 (new)
                  |        Branch 2 (new)
                  789a     Extension 2 (new)
                      |    Branch 1
                  bc...    Leaf (new)
__________________________________________________
]#
method put(ext: MptExtension, diffHeight: uint64, logicalDepth: uint8, key: Nibbles64, value: Buffer32):
    tuple[updatedNode: MptNode, missing: MptContinuation] =

  # Check if the key matches the (remainder of) the extension path
  var divergence = logicalDepth
  var offset = 0'u8
  while offset < ext.remainderPath.len and ext.remainderPath[offset] == key[divergence]:
    inc divergence
    inc offset

  # The key matches
  if offset == ext.remainderPath.len:

    # If the extension node belongs to another diff, clone it
    let clone =
      if ext.diffHeight == diffHeight: ext
      else: newExtension(diffHeight, ext.remainderPath, ext.child)

    # Call put() on the child branch, and update it afterwards in case it was cloned
    let res = clone.child.put(diffHeight, logicalDepth + ext.remainderPath.len, key, value)
    clone.child = cast[MptBranch](res.updatedNode)
    return (clone, res.missing)

  # The key differs
  else:
    # We create a new branch to hold the new leaf
    let branch2 = newBranch(diffHeight)
    branch2.children[key[divergence]] = newLeaf(diffHeight, key, value)

    # CASE #1 from documentation above
    if ext.remainderPath.len == 1:
      branch2.children[ext.remainderPath[0]] = ext.child
      return (branch2, nil)

    # CASE #2 from documentation above
    elif offset == 0:
      let remainderPath2 = ext.remainderPath.slice(1, ext.remainderPath.len - 1)
      let ext2 = newExtension(diffHeight, remainderPath2, ext.child)
      branch2.children[ext.remainderPath[0]] = ext2
      return (branch2, nil)

    # CASE #3 from documentation above
    elif offset == ext.remainderPath.len - 1:
      branch2.children[ext.remainderPath[offset]] = ext.child
      let ext2 = newExtension(diffHeight, ext.remainderPath.slice(0, offset), branch2)
      return (ext2, nil)

    # CASE #4 from documentation above
    else:
      let remainderPath2 = ext.remainderPath.slice(offset+1, ext.remainderPath.len - offset - 1)
      let ext2 = newExtension(diffHeight, remainderPath2, ext.child)
      branch2.children[ext.remainderPath[offset]] = ext2
      let remainderPath3 = ext.remainderPath.slice(0, offset)
      let ext3 = newExtension(diffHeight, remainderPath3, branch2)
      return (ext3, nil)



#[
  If the branch belongs to another diff, clone it.
  If the child denoted by `key` is nil, add a new leaf to the branch.
  If the child is `MptNotLoaded`, return that branch as the `closestNode`.
  Otherwise, call put() recursively and update the (possibly-cloned) child.
]#
method put(branch: MptBranch, diffHeight: uint64, logicalDepth: uint8, key: Nibbles64, value: Buffer32):
    tuple[updatedNode: MptNode, missing: MptContinuation] =
  let clone =
    if branch.diffHeight == diffHeight: branch
    else: newBranch(diffHeight, branch.children)
  if clone.children[key[logicalDepth]] == nil:
    clone.children[key[logicalDepth]] = newLeaf(diffHeight, key, value)
    return (clone, nil)
  elif clone.children[key[logicalDepth]] of MptNotLoaded:
    let continuation = MptContinuation(
      parentNode: clone,
      parentLogicalDepth: logicalDepth,
      originalTreePath: clone.children[key[logicalDepth]].MptNotLoaded.originalTreePath)
    return (clone, continuation)
  else:
    let res = clone.children[key[logicalDepth]].put(diffHeight, logicalDepth + 1, key, value)
    clone.children[key[logicalDepth]] = res.updatedNode
    return (clone, res.missing)



func put*(diff: var DiffLayer, key: Nibbles64, value: Buffer32): MptContinuation =
  ##[ Stores the given key-value in the tree, by inserting a new MptLeaf node, or updating an
      existing one. Changes to this tree do not affect `DiffLayer`s that this `DiffLayer` is based
      on. In case part of the tree needs to be loaded and the operation cannot be completed, a non-
      nil `MptContinuation` is returned. Once the missing subtree has been loaded and attached to
      the continuation's `parentNode`, call `put` again with the continuation to resume the
      operation. ]##
  if diff.root == nil:
    diff.root = newLeaf(diff.diffHeight, key, value)
  else:
    let res = diff.root.put(diff.diffHeight, 0, key, value)
    diff.root = res.updatedNode
    return res.missing



func put*(diff: var DiffLayer, cont: MptContinuation, key: Nibbles64, value: Buffer32): MptContinuation =
  ##[ Resumes storing the given key-value in the tree; see the other `put` overload. ]##
  let res = cont.parentNode.put(diff.diffHeight, cont.parentLogicalDepth, key, value)
  diff.root = res.updatedNode
  return res.missing



func tryGet(node: MptNode, logicalDepth: uint8, key: Nibbles64): tuple[value: MptLeaf, missing: MptContinuation] =
  var depth = logicalDepth
  var current = node
  while true:

    # Reached a leaf. If its path matches the key, return it. Otherwise return nil (not found).
    if current of MptLeaf:
      if current.MptLeaf.path.bytes == key.bytes:
        return (current.MptLeaf, nil)
      else: return (nil, nil)

    # Reached an extension. If its path matches the key, proceed with inspecting its child branch.
    # Otherwise return nil (not found).
    elif current of MptExtension:
      let ext = current.MptExtension
      for i in 0 ..< ext.remainderPath.len.int:
        if ext.remainderPath[i] != key[depth]:
          return (nil, nil)
        else: inc depth
      current = ext.child
      
    # Reached a branch. Resolve the child. If it's nil, return nil (not found). If it's a
    # MptNotLoaded node, return a continuation. Otherwise proceed inspecting the child.
    elif current of MptBranch:
      let child = current.MptBranch.children[key[depth]]
      if child == nil:
        return (nil, nil)
      elif child of MptNotLoaded:
        let continuation = MptContinuation(
          parentNode: current.MptBranch,
          parentLogicalDepth: depth,
          originalTreePath: child.MptNotLoaded.originalTreePath)
        return (nil, continuation)
      else:
        current = child
        inc depth



func tryGet*(diff: DiffLayer, key: Nibbles64): tuple[value: MptLeaf, missing: MptContinuation] =
  ##[ Fetches a value from the tree given a key. In case a value was not found, `nil` is returned.
      In case part of the tree needs to be loaded and the operation cannot be completed, a non-
      nil `MptContinuation` is returned in the `missing` field. Once the missing subtree has been
      loaded and attached to the continuation's `parentNode`, call `tryGet` again with the
      continuation to resume the operation. ]##
  tryGet(diff.root, 0, key)
  

func tryGet*(diff: DiffLayer, cont: MptContinuation, key: Nibbles64):
    tuple[value: MptLeaf, missing: MptContinuation] =
  ##[ Resumes fetching the given key from the tree; see the other `tryGet` overload. ]##
  tryGet(cont.parentNode, cont.parentLogicalDepth, key)
