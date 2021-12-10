# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ./rbtree_desc,
  ./rbtree_rotate,
  stew/results

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc rbTreeDelete*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function, removes a node from the red-black tree.
  ## The node to be removed wraps a data container `casket` matching the
  ## argument `key`, i.e. `rbt.cmp(casket,key) == 0`.
  ##
  ## If the node was successfully deleted, the function returns the matching
  ## `casket` data container. Otherwise, there was no such node with a matching
  ## `casket` in the tree.
  ##
  ## :Ackn:
  ##   `jsw_rberase()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if rbt.root.isNil:
    return err(rbEmptyTree)

  var
    dir = rbRight               # start here
    found: RbNodeRef[C]         # node to be removed (if any)
    head = RbNodeRef[C](
      link: [nil, rbt.root])    # black false tree root

    # ancestry line: g -> p -> q
    grandParent: RbNodeRef[C]   # grandparent => NIL
    parent: RbNodeRef[C]        # parent => NIL
    q = head                    # iterator

  # Search and push a red node down to fix red violations as we go
  while not q.link[dir].isNil:

    # Move the helpers down
    grandParent = parent
    parent = q
    q = q.link[dir]

    let
      last = dir
      diff = rbt.cmp(q.casket,key)
    dir = (diff < 0).toDir

    # Save matching node and keep going, removal job is done below this loop
    if diff == 0:
      found = q

    # Push the red node down with rotations and color flips
    if q.isRed or q.link[dir].isRed:
      continue

    if q.link[not dir].isRed:
      let qrs = q.rbTreeRotateSingle(dir)
      parent.link[last] = qrs
      parent = qrs

      # Mark traversal path unusable
      rbt.dirty = rbt.dirty or rbTreeReBalancedFlag
      continue

    # Now: not q.link[not dir].isRed
    let sibling = parent.link[not last]
    if sibling.isNil:
      continue

    # Note that `link.isRed` => `not link.isNil`
    if not sibling.linkLeft.isRed and not sibling.linkRight.isRed:
      # Color flip
      parent.isRed = false # aka black
      sibling.isRed = true
      q.isRed = true
      continue

    let dir2 = (grandParent.linkRight == parent).toDir
    if sibling.link[last].isRed:
      grandParent.link[dir2] = parent.rbTreeRotateDouble(last)
      rbt.dirty = rbt.dirty or rbTreeReBalancedFlag

    elif sibling.link[not last].isRed:
      grandParent.link[dir2] = parent.rbTreeRotateSingle(last)
      rbt.dirty = rbt.dirty or rbTreeReBalancedFlag

    # Ensure correct coloring
    q.isRed = true
    let ggp2 = grandParent.link[dir2]
    ggp2.isRed = true
    ggp2.linkLeft.isRed = false # aka black
    ggp2.linkRight.isRed = false # aka black

    # End while

  # Replace and remove the saved node */
  if found.isNil:
    result = err(rbNotFound)
  else:
    result = ok(found.casket)
    found.casket = q.casket

    let
      dirX = (parent.linkRight == q).toDir
      dirY = q.linkLeft.isNil.toDir
    parent.link[dirX] = q.link[dirY];
    # clear node cache if this was the one to be deleted
    if not rbt.cache.isNil and rbt.cmp(rbt.cache.casket,key) == 0:
      rbt.cache = nil
    q = nil # some hint for the GC to recycle that node

    rbt.size.dec
    rbt.dirty = rbt.dirty or rbTreeReBalancedFlag

  # Update the root (it may be different)
  rbt.root = head.linkRight

  # Mark the root black for simplified logic
  if not rbt.root.isNil:
    rbt.root.isRed = false # aka black

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
