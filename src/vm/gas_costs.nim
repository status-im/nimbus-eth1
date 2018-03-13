import
  strformat, ttmath,
  ../types, ../constants, ../opcode, ../computation, stack

proc expGasCost*(computation: var BaseComputation): UInt256 =
  let arg = computation.stack.getInt(0)
  result = if arg == 0: 10.u256 else: (10.u256 + 10.u256 * (1.u256 + arg.log256))
  
