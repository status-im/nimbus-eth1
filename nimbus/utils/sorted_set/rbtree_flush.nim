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
  ./rbtree_desc

type
  RbTreeFlushDel*[C] = proc(c: var C) {.gcsafe.}

{.push raises: [Defect].}

# ----------------------------------------------------------------------- ------
# Private
# ------------------------------------------------------------------------------

# Default clean up function
proc defaultClup[C](casket: var C) {.inline.} =
  # smarty here ...
  discard

# ----------------------------------------------------------------------- ------
# Public
# ------------------------------------------------------------------------------

proc rbTreeFlush*[C,K](rbt: RbTreeRef[C,K];
                       clup: RbTreeFlushDel[C] = nil): bool
                       {.gcsafe,discardable.} =
  ## Clears/flushes a valid red-black tree while passing each data container
  ## `casket` to the clean up argument function `clup()` before removing it.
  ##
  ## The flush function returns `false` and stops immediately if another flush
  ## instance is already running. On a single thread execution model, this can
  ## only happen if this very same function is called from within the cleanup
  ## function argument `clup()`.
  ##
  ## :Ackn:
  ##   `jsw_rbdelete()` from jsw_rbtree.c from captured C library
  ##   `jsw_rbtree.zip <https://web.archive.org/web/20160428112900/http://eternallyconfuzzled.com/libs/jsw_rbtree.zip>`_.
  ##
  if (rbt.dirty and rbTreeFlushDataFlag) != 0:
    return false
  rbt.dirty = rbt.dirty or rbTreeFlushDataFlag

  # clear node cache
  rbt.cache = nil

  var
    cleanUp = clup
    save: RbNodeRef[C]
    it = rbt.root

  if cleanUp.isNil:
    # Need `proc()` wrapper around generic `defaultClup[C]()` as the function
    # pointer `defaultClup` exists only with its incarnation,
    cleanUp = proc(c: var C) = c.defaultClup

  # GC hint, reset node reference early so there is no remaining
  # top level link left when cleaning up right node chain
  rbt.root = nil

  # Rotate away the left links so that we can treat this like
  # the destruction of a linked list
  while not it.isNil:

    if it.linkLeft.isNil:
      # No left links, just kill the node and move on
      save = it.linkRight

      it.casket.cleanUp
      it = nil # GC hint

    else:
      # Rotate away the left link and check again
      save = it.linkLeft
      it.linkLeft = save.linkRight
      save.linkRight = it

    it = save
    # End while

  rbt.size = 0
  rbt.dirty = rbTreeNodesDeletedFlag or rbTreeReBalancedFlag

  true

# ----------------------------------------------------------------------- ------
# End
# ------------------------------------------------------------------------------
