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
  std/[tables],
  ./rbtree_desc,
  stew/results

{.push raises: [Defect].}

# ----------------------------------------------------------------------- ------
# Priv
# ------------------------------------------------------------------------------

proc walkMove[C,K](w: RbWalkRef[C,K]; dir: RbDir): RbResult[C] =
  ## Traverse a red black tree in the user-specified direction.
  ##
  ## :Returns:
  ##    Next data value in the specified direction
  ##
  ## Ackn:
  ##   `move()` from jsw_rbtree.c
  ##
  w.start = false

  if not w.node.link[dir].isNil:

    # Continue down this branch
    w.path[w.top] = w.node
    w.top.inc
    w.node = w.node.link[dir]

    while not w.node.link[not dir].isNil:
      w.path[w.top] = w.node
      w.top.inc

      if w.path.len <= w.top:
        w.path.setLen(w.path.len + 10)
      w.node = w.node.link[not dir]

    return ok(w.node.casket)

  # Move to the next branch
  while 0 < w.top:
    let last = w.node
    w.top.dec
    w.node = w.path[w.top]

    if last != w.node.link[dir]:
      return ok(w.node.casket)

  # now: w.top == 0
  w.node = nil
  w.stop = true
  return err(rbEndOfWalk)


proc walkStart[C,K](w: RbWalkRef[C,K]; dir: RbDir): RbResult[C] =
  ## Rewind the traversal position to the left-most or-right-most position
  ## as defined by the function argument `dir`. After successfully rewinding,
  ## the desriptor is in `start` position (see `walkClearDirty()`).
  ##
  ## :Returns:
  ##   Left-most or-right-most data container.
  ##
  ## :Ackn:
  ##   see start() from jsw_rbtree.c
  ##
  w.node = w.tree.root
  w.top = 0

  if w.node.isNil:
    return err(rbWalkClosed)

  # Save the path for later traversal
  while not w.node.link[dir].isNil:

    if w.path.len <= w.top:
      w.path.setLen(w.path.len + 10)

    w.path[w.top] = w.node
    w.top.inc

    w.node = w.node.link[dir]

  w.start = true
  return ok(w.node.casket)


proc walkClearDirtyFlags[C,K](w: RbWalkRef[C,K]): bool =
  ## Clear dirty flag if all traversal descriptors are in `start` postion.
  if w.tree.dirty != 0:
    for u in w.tree.walks.values:
      # At least one is not rewound => fail
      if not u.start:
        return false
    w.tree.dirty = 0

  w.stop = false
  return true

# ----------------------------------------------------------------------- ------
# Public constructor/desctructor
# ------------------------------------------------------------------------------

proc newRbWalk*[C,K](rbt: RbTreeRef[C,K]): RbWalkRef[C,K] =
  ## Generic red-black tree function, creates a new traversal descriptor on the
  ## argument red-black tree `rbt`.
  ##
  ## :Ackn:
  ##   `jsw_rbtnew()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  result = RbWalkRef[C,K](
    id: rbt.newWalkId,
    tree: rbt,
    path: newSeq[RbNodeRef[C]](32), # space for approx 2^16 leafs
    start: true)                    # unblock for `walkClearDirty()`
  doAssert result.id != 0
  rbt.walks[result.id] = result     # register in parent descriptor


proc rbWalkDestroy*[C,K](w: RbWalkRef[C,K]) =
  ## Explicit destructor for current walk descriptor `w`. Clears the descriptor
  ## argument `w`.
  ##
  ## This destructor function is crucial when insert/delete tree operations
  ## are executed while traversals are open. These insert/delete functions
  ## modify the tree so that `rbWalkThis()`, `rbWalkPrev()`, etc. operations
  ## will fail. All traversal descriptors must then be rewound or destroyed.
  if not w.tree.isNil:
    w.tree.walks.del(w.id)
    w.tree = nil # notify GC
    w.node = nil
    w.path = @[]
    w[].reset

proc rbWalkDestroyAll*[C,K](rbt: RbTreeRef[C,K]) =
  ## Apply `rbWalkDestroy()` to all registered walk descriptors.
  for w in rbt.walks.values:
    w.tree = nil # notify GC (if any, todo?)
    w.node = nil
    w.path = @[]
    w[].reset    # clear
  rbt.walks = initTable[uint,RbWalkRef[C,K]](1)

proc rbWalkDestroyAll*[C,K](w: RbWalkRef[C,K]) =
  ## Variant of `rbWalkDestroyAll()`
  if not w.tree.isNil:
    w.tree.rbWalkDestroyAll

# ----------------------------------------------------------------------- ------
# Public functions: rewind
# ------------------------------------------------------------------------------

proc rbWalkFirst*[C,K](w: RbWalkRef[C,K]): RbResult[C] =
  ## Move to the beginning of the tree (*smallest* item) and return the
  ## corresponding data container of type `C`.
  ##
  ## When all traversals are rewound, blockers due to tree insert/delete
  ## operations are reset.
  ##
  ## :Ackn:
  ##   `jsw_rbtfirst()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if w.tree.isNil:
    return err(rbWalkClosed)

  # Reset dirty flag unless other traversal descriptors are open
  if not w.walkClearDirtyFlags:
    return err(rbWalkBlocked)

  return w.walkStart(rbLeft)


proc rbWalkLast*[C,K](w: RbWalkRef[C,K]): RbResult[C] =
  ## Move to the end of the tree (*greatest* item) and return the corresponding
  ## data container of type `C`.
  ##
  ## When all traversals are rewound, blockers due to tree insert/delete
  ## operations are reset.
  ##
  ## :Ackn:
  ##   `jsw_rbtlast()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if w.tree.isNil:
    return err(rbWalkClosed)

  # Reset dirty flag unless other traversal descriptors are open
  if not w.walkClearDirtyFlags:
    return err(rbWalkBlocked)

  return w.walkStart(rbRight)

# ----------------------------------------------------------------------- ------
# Public functions: traversal, get data entry
# ------------------------------------------------------------------------------

proc rbWalkCurrent*[C,K](w: RbWalkRef[C,K]): RbResult[C] =
  ## Retrieves the data container of type `C` for the current node. Note that
  ## the current node becomes unavailable if it was recently deleted.
  ##
  if w.node.isNil:
    if w.tree.isNil:
      return err(rbWalkClosed)
    return err(rbEndOfWalk)

  # Node exits => tree exists
  if (w.tree.dirty and rbTreeNodesDeletedFlag) != 0:
    return err(rbWalkBlocked)

  return ok(w.node.casket)



proc rbWalkNext*[C,K](w: RbWalkRef[C,K]): RbResult[C] =
  ## Traverse to the next value in ascending order and return the corresponding
  ## data container of type `C`. If this is the first call after `newRbWalk()`,
  ## then `rbWalkFirst()` is called implicitly.
  ##
  ## If there were tree insert/delete operations, blockers might be active
  ## causing this function to fail so that a rewind is needed.
  ##
  ## :Ackn:
  ##   `jsw_rbtnext()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if not w.node.isNil:
    # Node exits => tree exists
    if w.tree.dirty != 0:
      return err(rbWalkBlocked)
    return w.walkMove(rbRight)

  # End of travesal reached?
  if w.stop:
    return err(rbEndOfWalk)
  if w.tree.isNil:
    return err(rbWalkClosed)

  # Reset dirty flag unless other traversal descriptors are open
  if not w.walkClearDirtyFlags:
    return err(rbWalkBlocked)

  return w.walkStart(rbLeft) # minimum index item


proc rbWalkPrev*[C,K](w: RbWalkRef[C,K]): RbResult[C] =
  ## Traverse to the next value in descending order and return the
  ## corresponding data container of type `C`. If this is the first call
  ## after `newRbWalk()`, then `rbWalkLast()` is called implicitly.
  ##
  ## If there were tree insert/delete operations, blockers might be active
  ## causing this function to fail so that a rewind is needed.
  ##
  ## :Ackn:
  ##   `jsw_rbtprev()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if not w.node.isNil:
    # Node exits => tree exists
    if w.tree.dirty != 0:
      return err(rbWalkBlocked)
    return w.walkMove(rbLeft)

  # End of travesal reached?
  if w.stop:
    return err(rbEndOfWalk)
  if w.tree.isNil:
    return err(rbWalkClosed)

  # Reset dirty flag unless other traversal descriptors are open
  if not w.walkClearDirtyFlags:
    return err(rbWalkBlocked)

  return w.walkStart(rbRight)  # maximum index item

# ----------------------------------------------------------------------- ------
# End
# ------------------------------------------------------------------------------
