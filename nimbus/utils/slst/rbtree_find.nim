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
  stew/results

{.push raises: [Defect].}

# ----------------------------------------------------------------------- ------
# Public
# ------------------------------------------------------------------------------

proc rbTreeFindEq*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function. Search for a data container `casket` of
  ## type `C` in the red black tree which matches the argument `key`,
  ## i.e. `rbt.cmp(casket,key) == 0`. If found, this data container `casket` is
  ## returned, otherwise an error code is returned.
  ##
  ## :Ackn:
  ##   `jsw_rbfind()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if rbt.root.isNil:
    return err(rbEmptyTree)

  if not rbt.cache.isNil and rbt.cmp(rbt.cache.casket,key) == 0:
    return ok(rbt.cache.casket)

  var
    q = rbt.root
  while not q.isNil:
    let diff = rbt.cmp(q.casket,key)

    if diff == 0:
      return ok(q.casket)

    # FIXME: If the tree supports duplicates, they should be
    # chained to the right subtree for this to work
    let dir2 = (diff < 0).toDir
    q = q.link[dir2]

  return err(rbNotFound)


proc rbTreeFindGe*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function. Search for the *smallest* data container
  ## `casket` of type `C` which is *greater or equal* to the specified argument
  ## `key` in the red black-tree. If such a  data container is found in the
  ## tree it is returned, otherwise an error code is returned.
  ##
  ## If found in the tree, this data container `casket` satisfies
  ## `0 <= cmp(casket,key)` and there is no *smaller* data container relative
  ## to `casket` in the red-black tree satisfying this condition.
  ##
  ##
  ## For a more formal reasoning of *smaller* and *greater*, consider the
  ## injection `mkc:K -> C` which is used to create data containers of type `C`
  ## from a key of type `K`. Let `mkc':K -> C'` be the map onto the
  ## equivalence class `C'` where `x` is in a class `mkc'(key)` if
  ## `cmp(x,key) == 0` (i.e. `x` is a later modification of a data container
  ## originally created as `mkc(key)`.)
  ##
  ## Then `mkc'` is an isomorphism.and there is the natural order relation on
  ## `C'` which is extended from the order relation on `K`. So the returned
  ## result is `min(v' of C': key <= v')` which is `mkc(key)` apart from
  ## data container modifications.
  ##
  if rbt.root.isNil:
    return err(rbEmptyTree)

  # Always: not itemOk or key <= item
  var
    itemOk = false
    item: C
    q = rbt.root
  while true:
    var
      nxt: RbNodeRef[C]
      diff = rbt.cmp(q.casket,key)

    if 0 < diff:        # key < q.casket
      itemOk = true     # remember item
      item = q.casket   # now: key < item
      nxt = q.linkLeft  # move left => get strictly smaller items

    elif diff < 0:
      nxt = q.linkRight # move right => see strictly larger items

    else:
      return ok(q.casket)

    if nxt.isNil:
      if itemOk:
        return ok(item)
      break

    q = nxt
    # End while

  return err(rbNotFound)


proc rbTreeFindGt*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function. Search for the *smallest* data container
  ## of type `C` which is *strictly greater* than the specified argument `key`
  ## in the red-black tree.
  ##
  ## See comments on `rbTreeFindGe()` for a formal definition of how to apply
  ## an order relation on `C`.
  if rbt.root.isNil:
    return err(rbEmptyTree)

  # Always: not itemOk or key < item
  var
    itemOk = false
    item: C
    q = rbt.root
  while true:
    var
      nxt: RbNodeRef[C]
      diff = rbt.cmp(q.casket,key)

    if 0 < diff:        # key < q.casket
      itemOk = true     # remember item
      item = q.casket   # now: key < item
      nxt = q.linkLeft  # move left => get strictly smaller items

    else:
      nxt = q.linkRight # move right => see probably larger items

    if nxt.isNil:
      if itemOk:
        return ok(item)
      break

    q = nxt
    # End while

  return err(rbNotFound)


proc rbTreeFindLe*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function. Search for the *greatest* data container
  ## of type `C` which is *less than or equal* to the specified argument
  ## `key` in the red-black tree.
  ##
  ## See comments on `rbTreeFindGe()` for a formal definition of how to apply
  ## an order relation on `C`.
  if rbt.root.isNil:
    return err(rbEmptyTree)

  # Always: not itemOk or item < key
  var
    itemOk = false
    item: C
    q = rbt.root
  while true:
    var
      nxt: RbNodeRef[C]
      diff = rbt.cmp(q.casket,key)

    if diff < 0:        #  q.casket < key
      itemOk = true     # remember item
      item = q.casket   # now: item < key
      nxt = q.linkRight # move right => get strictly larger items

    elif 0 < diff:
      nxt = q.linkLeft  # move left => see strictly smaller items

    else:
      return ok(q.casket)

    if nxt.isNil:
      if itemOk:
        return ok(item)
      break

    q = nxt
    # End while

  return err(rbNotFound)


proc rbTreeFindLt*[C,K](rbt: RbTreeRef[C,K]; key: K): RbResult[C] =
  ## Generic red-black tree function. Search for the *greatest* data container
  ## of type `C` which is *strictly less* than the specified argument `key` in
  ## the red-black tree.
  ##
  ## See comments on `rbTreeFindGe()` for a formal definition of how to apply
  ## an order relation on `C`.
  if rbt.root.isNil:
    return err(rbEmptyTree)

  # Always: not itemOk or item < key
  var
    itemOk = false
    item: C
    q = rbt.root
  while true:
    var
      nxt: RbNodeRef[C]
      diff = rbt.cmp(q.casket,key)

    if diff < 0:        #  q.casket < key
      itemOk = true     # remember item
      item = q.casket   # now: item < key
      nxt = q.linkRight # move right => get larger items

    else:
      nxt = q.linkLeft  # move left => see probably smaller items

    if nxt.isNil:
      if itemOk:
        return ok(item)
      break

    q = nxt
    # End while

  return err(rbNotFound)

# ----------------------------------------------------------------------- ------
# End
# ------------------------------------------------------------------------------
