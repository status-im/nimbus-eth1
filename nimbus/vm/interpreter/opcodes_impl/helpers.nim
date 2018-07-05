# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros,
  eth_common/eth_types

template pushRes*: untyped =
  computation.stack.push(res)

macro quasiBoolean*(name: untyped, op: untyped, signed: untyped = nil, nonzero: untyped = nil): untyped =
  var signedNode = newEmptyNode()
  var finishSignedNode = newEmptyNode()
  let resNode = ident("res")
  var leftNode = ident("left")
  var rightNode = ident("right")
  var actualLeftNode = leftNode
  var actualRightNode = rightNode
  if not signed.isNil:
    actualLeftNode = ident("leftSigned")
    actualRightNode = ident("rightSigned")
    signedNode = quote:
      let `actualLeftNode` = cast[Int256](`leftNode`)
      let `actualRightNode` = cast[Int256](`rightNode`)
  var test = if nonzero.isNil:
      quote:
        `op`(`actualLeftNode`, `actualRightNode`)
    else:
      quote:
        `op`(`actualLeftNode`, `actualRightNode`) != 0
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      var (`leftNode`, `rightNode`) = computation.stack.popInt(2)
      `signedNode`

      var `resNode` = if `test`: 1.u256 else: 0.u256
      computation.stack.push(`resNode`)
