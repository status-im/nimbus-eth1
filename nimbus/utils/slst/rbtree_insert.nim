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

# ----------------------------------------------------------------------- ------
# Private functions
# ------------------------------------------------------------------------------

proc insertRoot[C,K](rbt: RbTreeRef[C,K]; key: K): C {.inline.} =
  ## Insert item `x` into an empty tree.
  rbt.root = RbNodeRef[C](
    casket: rbt.mkc(key))
  rbt.size = 1
  rbt.root.casket

proc insertNode[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] {.inline.} =
  ## Insert item `key` into a non-empty tree.

  doAssert not rbt.root.isNil

  var
    dir = rbLeft
    last = dir                  # always previous value of `dir`
    insertOk = false
    head = RbNodeRef[C](
      link: [nil, rbt.root])    # black fake tree root

    # ancestry line: t -> g -> p -> q
    greatGrandParent = head     # ancestor, fake (black) super root
    grandParent: RbNodeRef[C]   # grandparent => NIL
    parent: RbNodeRef[C]        # parent => NIL
    q = rbt.root                # initialise iterator to not-NIL tree root

  # Search down the tree for a place to insert
  while true:

    if q.isNil:
      # Insert new (red) node at the first NIL link
      insertOk = true
      q = RbNodeRef[C](
        casket: rbt.mkc(key))
      q.isRed = true
      parent.link[dir] = q

    elif q.linkLeft.isRed and q.linkRight.isRed:
      # Simple red violation: colour flip
      q.isRed = true
      q.linkLeft.isRed = false # aka black
      q.linkRight.isRed = false # aka black

    # Fix red violation: rotations necessary
    if q.isRed and parent.isRed:
      let dir2 = (greatGrandParent.linkRight == grandParent).toDir
      greatGrandParent.link[dir2] =
        if parent.link[last] == q: grandParent.rbTreeRotateSingle(not last)
        else:                      grandParent.rbTreeRotateDouble(not last)

      # Mark traversal path unusable
      rbt.dirty = rbt.dirty or rbTreeReBalancedFlag

    # Stop working if we inserted a node. This check also disallows
    # duplicates in the tree.
    let diff = rbt.cmp(q.casket,key)
    if diff == 0:
      break ;

    last = dir
    dir = (diff < 0).toDir

    # Shift the helpers down the ancestry line
    if not grandParent.isNil:
      greatGrandParent = grandParent
    grandParent = parent
    parent = q
    q = q.link[dir]

    # End while

  # Update the root (it may be different)
  rbt.root = head.linkRight

  # Make the root black for simplified logic
  rbt.root.isRed = false # aka black

  # Save last node in cache (speeds up some find operation)
  rbt.cache = q

  if insertOk:
    rbt.size.inc
    return ok(q.casket)

  return err(rbExists)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc rbTreeInsert*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function, inserts a data container `casket` derived
  ## from argument `key` into the red-black tree.
  ##
  ## If a new node was successfully created, the function returns the `casket`
  ## data container matching the `key` argument (i.e.
  ## `rbt.cmp(casket,key) == 0`). Otherwise, if the `key` argument was in the
  ## tree already an error code is returned. In that case, the data container
  ## can can be retrieved with `rbTreeFindEq()`.
  ##
  ## :Ackn:
  ##   `jsw_rbinsert()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if rbt.root.isNil:
    return ok(rbt.insertRoot(key))
  rbt.insertNode(key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
