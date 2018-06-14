# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./impl_std_import

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

# TODO template handler

proc mstore*(computation) =
  let start = stack.popInt().toInt
  let normalizedValue = stack.popInt().toByteArrayBE

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore].m_handler(computation.memory.len, start, 32),
    reason="MSTORE: GasVeryLow + memory expansion"
    )

  memory.extend(start, 32)
  memory.write(start, normalizedValue)

proc mstore8*(computation) =
  let start = stack.popInt().toInt
  let value = stack.popInt()
  let normalizedValue = (value and 0xff).toByteArrayBE

  computation.gasMeter.consumeGas(
    computation.gasCosts[MStore8].m_handler(computation.memory.len, start, 1),
    reason="MSTORE8: GasVeryLow + memory expansion"
    )

  memory.extend(start, 1)
  memory.write(start, [normalizedValue[0]])

proc mload*(computation) =
  let start = stack.popInt().toInt

  computation.gasMeter.consumeGas(
    computation.gasCosts[MLoad].m_handler(computation.memory.len, start, 32),
    reason="MLOAD: GasVeryLow + memory expansion"
    )

  memory.extend(start, 32)
  let value = memory.read(start, 32)
  stack.push(value)

proc msize*(computation) =
  stack.push(memory.len.u256)
