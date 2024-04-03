#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./[mpt, mpt_nibbles]

export mpt, mpt_nibbles


func shallowCloneMptNode(node: MptNode): MptNode =
  if node of MptLeaf:
    result = MptLeaf()
    result.MptLeaf[] = node.MptLeaf[]

  elif node of MptAccount:
    result = MptAccount()
    result.MptAccount[] = node.MptAccount[]

  elif node of MptExtension:
    result = MptExtension()
    result.MptExtension[] = node.MptExtension[]

  else:
    result = MptBranch()
    result.MptBranch[] = node.MptBranch[]


func stackDiffLayer*(base: DiffLayer): DiffLayer =
  ## Create a new diff layer, using a shallow clone of the base layer's root and
  ## an incremented diffHeight. Descendants will be cloned when they're on the
  ## path of a node being updated.
  if base.root != nil:
    result.root = base.root.shallowCloneMptNode
  result.diffHeight = base.diffHeight + 1


proc put*(diff: var DiffLayer, key: Nibbles64, value: seq[byte]) =
  
  # No root? Store a leaf
  if diff.root == nil:
    diff.root = MptLeaf(diffHeight: diff.diffHeight, logicalDepth: 0, path: key, value: value)

  # Root is a leaf? (cloned)
  elif diff.root of MptLeaf:

    # Same path? Update value
    if diff.root.MptLeaf.path == key:
      diff.root.MptLeaf.value = value

    # Different? Find the point at which they diverge
    else:
      var divergeDepth = 0.uint8
      while diff.root.MptLeaf.path[divergeDepth] == key[divergeDepth]:
        inc divergeDepth

      # Create a branch to hold the current leaf, and add a new leaf
      let rootNibble = diff.root.MptLeaf.path[divergeDepth]
      let keyNibble = key[divergeDepth]
      let bits = (0x8000.uint16 shr rootNibble) or (0x8000.uint16 shr keyNibble)
      let branch = MptBranch(diffHeight: diff.diffHeight, logicalDepth: divergeDepth, childExistFlags: bits)
      diff.root.logicalDepth = divergeDepth + 1
      branch.children[rootNibble] = diff.root
      branch.children[keyNibble] = MptLeaf(diffHeight: diff.diffHeight,
        logicalDepth: divergeDepth + 1, path: key, value: value)

      # Diverging right from the start? Replace the root node with the branch
      if divergeDepth == 0:
        diff.root = branch

      # Oterwise, replace the root node with an extension node that holds the
      # branch. The extension node's remainder path extends till the point of
      # divergence.
      else:
        diff.root = MptExtension(diffHeight: diff.diffHeight, logicalDepth: 0,
          child: branch, remainderPath: key.slice(0, divergeDepth))

  # Root is an extension?
  elif diff.root of MptExtension:
    let extPath = diff.root.MptExtension.remainderPath

    # The key path starts with a different nibble? Replace the root by a branch,
    # put the current extension in it (minus the leading nibble) and add a new
    # leaf
    if extPath[0] != key[0]:
      let bits = (0x8000.uint16 shr extPath[0]) or (0x8000.uint16 shr key[0])
      let branch = MptBranch(diffHeight: diff.diffHeight, logicalDepth: 0, childExistFlags: bits)
      branch.children[extPath[0]] = MptExtension(diffHeight: diff.diffHeight, logicalDepth: 1,
        child: diff.root.MptExtension.child, childHashOrRlp: diff.root.MptExtension.childHashOrRlp,
        remainderPath: extPath.slice(1, extPath.len-1))
      branch.children[key[0]] = MptLeaf(diffHeight: diff.diffHeight,
        logicalDepth: extPath.len.uint8 - 2, path: key, value: value)
      diff.root = branch

  else: doAssert false
