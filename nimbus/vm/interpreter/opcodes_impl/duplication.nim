# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros, strformat, ./impl_std_import

macro dupXX(position: static[int]): untyped =
  let name = ident(&"dup{position}")
  result = quote:
    proc `name`*(computation: var BaseComputation) =
      computation.stack.dup(`position`)

dupXX(1)
dupXX(2)
dupXX(3)
dupXX(4)
dupXX(5)
dupXX(6)
dupXX(7)
dupXX(8)
dupXX(9)
dupXX(10)
dupXX(11)
dupXX(12)
dupXX(13)
dupXX(14)
dupXX(15)
dupXX(16)

