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
  ./rbtree_flush,
  ./rbtree_walk

{.push raises: [Defect].}

# ----------------------------------------------------------------------- ------
# Public
# ------------------------------------------------------------------------------

proc rbTreeReset*[C,K](rbt: RbTreeRef[C,K]; clup: RbTreeFlushDel[C] = nil) =
  ## Destroys/clears the argumnnt red-black tree descriptor and all registered
  ## walk descriptors by calling `rbTreeFlush()` and `rbWalkDestroy()`.
  ##
  ## The function argument `clup` is passed on to `rbTreeFlush()`.
  ##
  ## After return, the argument tree descriptor is reset to its initial and
  ## empty state.
  rbt.rbWalkDestroyAll
  rbt.rbTreeFlush(clup = clup)
  rbt.dirty = 0

# ----------------------------------------------------------------------- ------
# End
# ------------------------------------------------------------------------------
