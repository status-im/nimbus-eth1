# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, ./impl_std_import

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc stop*(computation) =
  raise newException(HaltError, "STOP")


proc jump*(computation) =
  let jumpDest = stack.popInt.toInt
  code.pc = jumpDest

  let nextOpcode = code.peek()

  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  if not code.isValidOpcode(jumpDest):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpi*(computation) =
  let (jumpDest, checkValue) = stack.popInt(2)

  if checkValue > 0:
    code.pc = jumpDest.toInt

    let nextOpcode = code.peek()

    if nextOpcode != JUMPDEST:
      raise newException(InvalidJumpDestination, "Invalid Jump Destination")

    if not code.isValidOpcode(jumpDest.toInt):
      raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpdest*(computation) =
  discard

proc pc*(computation) =
  let pc = max(code.pc - 1, 0).u256
  stack.push(pc)

proc gas*(computation) =
  let gasRemaining = gasMeter.gasRemaining
  stack.push(gasRemaining.u256)
