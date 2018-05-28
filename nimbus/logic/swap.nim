# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros, strformat,
  ../vm_types, ../computation, ../vm/stack

macro swapXX(position: static[int]): untyped =
  let name = ident(&"swap{position}")
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      computation.stack.swap(`position`)

swapXX(0)
swapXX(1)
swapXX(2)
swapXX(3)
swapXX(4)
swapXX(5)
swapXX(6)
swapXX(7)
swapXX(8)
swapXX(9)
swapXX(10)
swapXX(11)
swapXX(12)
swapXX(13)
swapXX(14)
swapXX(15)
swapXX(16)
