# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, stint,
  ../types, ../constants, ../opcode, ../computation, stack

proc expGasCost*(computation: var BaseComputation): UInt256 =
  let arg = computation.stack.getInt(0)
  result = if arg == 0: 10.u256 else: (10.u256 + 10.u256 * (1.u256 + arg.log256))

