import
  ../errors, ../types, ../computation

proc invalidOp*(computation: var BaseComputation) =
  raise newException(InvalidInstruction, "Invalid opcode")
