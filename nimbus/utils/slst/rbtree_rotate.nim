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

{.push raises: [Defect].}

proc rbTreeRotateSingle*[C](node: RbNodeRef[C]; dir: RbDir): RbNodeRef[C] =
  ## Perform a single red-black tree rotation in the specified direction.
  ## This function assumes that all nodes are valid for a rotation.
  ##
  ## Params:
  ##   :node: The root node to rotate around
  ##   :dir:  The direction to rotate (left or right)
  ##
  ## Returns:
  ##   The new root after rotation
  ##
  let save = node.link[not dir]

  node.link[not dir] = save.link[dir]
  save.link[dir] = node

  node.isRed = true
  save.isRed = false # aka black

  save


proc rbTreeRotateDouble*[C](node: RbNodeRef[C]; dir:  RbDir): RbNodeRef[C] =
  ## Perform a double red-black rotation in the specified direction.
  ## This function assumes that all nodes are valid for a rotation.
  ##
  ## Params:
  ##  :node: The root node to rotate around
  ##  :dir:  The direction to rotate (0 = left, 1 = right)
  ##
  ## Returns:
  ##  The new root after rotation.
  ##
  node.link[not dir] = node.link[not dir].rbTreeRotateSingle(not dir)
  node.rbTreeRotateSingle(dir)

# End
