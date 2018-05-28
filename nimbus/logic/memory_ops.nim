# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../constants, ../computation, ../vm_types, .. / vm / [stack, memory], .. / utils / [padding, bytes],
  stint


{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc mstoreX(computation; x: int) =
  let start = stack.popInt().toInt
  let value = stack.popBinary()

  let paddedValue = padLeft(value, x, 0.byte)
  let normalizedValue = paddedValue[^x .. ^1]

  extendMemory(start, x)
  memory.write(start, 32, normalizedValue)

# TODO template handler

proc mstore*(computation) =
  mstoreX(32)

proc mstore8*(computation) =
  mstoreX(1)

proc mload*(computation) =
  let start = stack.popInt().toInt

  extendMemory(start, 32)

  let value = memory.read(start, 32)
  stack.push(value)

proc msize*(computation) =
  stack.push(memory.len.u256)
