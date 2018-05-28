# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../constants, ../utils_numeric, .. / utils / [keccak, bytes], .. / vm / [stack, memory, gas_meter], ../computation, ../vm_types, helpers, stint

proc sha3op*(computation: var BaseComputation) =
  let (startPosition, size) = computation.stack.popInt(2)
  let (pos, len) = (startPosition.toInt, size.toInt)
  computation.extendMemory(pos, len)
  let sha3Bytes = computation.memory.read(pos, len)
  let wordCount = sha3Bytes.len.ceil32 div 32 # TODO, can't we just shr instead of rounding + div
  let gasCost = constants.GAS_SHA3_WORD * wordCount
  computation.gasMeter.consumeGas(gasCost, reason="SHA3: word gas cost")
  var res = keccak("")
  pushRes()
