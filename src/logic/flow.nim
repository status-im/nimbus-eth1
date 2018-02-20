import
  strformat, ttmath,
  ../constants, ../opcode_values, ../logging, ../errors, ../computation, .. /vm / [code_stream, stack]


{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc stop*(computation) =
  raise newException(Halt, "STOP")


proc jump*(computation) =
  let jumpDest = stack.popInt.getUInt.int

  code.pc = jumpDest

  let nextOpcode = code.peek()

  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  if not code.isValidOpcode(jumpDest):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpi*(computation) =
  let (jumpDest, checkValue) = stack.popInt(2)

  if checkValue > 0:
    code.pc = jumpDest.getUInt.int

    let nextOpcode = code.peek()

    if nextOpcode != JUMPDEST:
      raise newException(InvalidJumpDestination, "Invalid Jump Destination")

    if not code.isValidOpcode(jumpDest.getUInt.int):
      raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpdest*(computation) =
  discard

proc pc*(computation) =
  let pc = max(code.pc - 1, 0).u256
  stack.push(pc)

proc gas*(computation) =
  let gasRemaining = gasMeter.gasRemaining
  stack.push(gasRemaining)
