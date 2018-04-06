# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../constants, ../utils_numeric, .. / utils / [keccak, bytes], .. / vm / [stack, memory, gas_meter], ../computation, ../types, helpers, ttmath

proc sha3op*(computation: var BaseComputation) =
  let (startPosition, size) = computation.stack.popInt(2)
  computation.extendMemory(startPosition, size)
  let sha3Bytes = computation.memory.read(startPosition, size)
  let wordCount = sha3Bytes.len.u256.ceil32 div 32
  let gasCost = constants.GAS_SHA3_WORD * wordCount
  computation.gasMeter.consumeGas(gasCost, reason="SHA3: word gas cost")
  var res = keccak("")
  pushRes()
