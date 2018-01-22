import
  strformat, bigints,
  ../constants, ../opcode_values, ../logging, ../errors, ../computation, .. /vm / [code_stream, stack]

proc stop*(computation: var BaseComputation) =
  raise newException(Halt, "STOP")


proc jump*(computation: var BaseComputation) =
  var jumpDest = computation.stack.popInt.getInt

  computation.code.pc = jumpDest

  let nextOpcode = computation.code.peek()

  if nextOpcode != JUMPDEST:
    raise newException(InvalidJumpDestination, "Invalid Jump Destination")

  if not computation.code.isValidOpcode(jumpDest):
    raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpi*(computation: var BaseComputation) =
  var (jumpDest, checkValue) = computation.stack.popInt(2)

  if checkValue > 0:
    computation.code.pc = jumpDest.getInt

    let nextOpcode = computation.code.peek()

    if nextOpcode != JUMPDEST:
      raise newException(InvalidJumpDestination, "Invalid Jump Destination")

    if not computation.code.isValidOpcode(jumpDest.getInt):
      raise newException(InvalidInstruction, "Jump resulted in invalid instruction")

proc jumpdest*(computation: var BaseComputation) =
  discard

proc pc*(computation: var BaseComputation) =
  var pc = max(computation.code.pc - 1, 0)
  computation.stack.push(pc)

proc gas*(computation: var BaseComputation) =
  var gasRemaining = computation.gasMeter.gasRemaining
  computation.stack.push(gasRemaining)
