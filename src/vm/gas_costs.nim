import
  strformat, ttmath,
  ../constants, ../opcode, ../computation, stack

proc expGasCost*(computation: var BaseComputation): Int256 =
  let arg = computation.stack.getInt(0)
  result = if arg == 0: 10.i256 else: (10.i256 + 10.i256 * (1.i256 + arg.log256))
  
