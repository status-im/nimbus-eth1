import
  strformat, strutils, sequtils, macros,
  constants, logging, errors, opcode_values, computation, vm/stack, bigints

type
  Opcode* = ref object of RootObj

method run*(opcode: var Opcode, computation: var BaseComputation) {.base.} =
  # Hook for performing the actual VM execution.
  raise newException(ValueError, "Must be implemented by subclasses")

method kind*(opcode: Opcode): Op {.base.} =
  raise newException(ValueError, "Must be implemented by subclasses")

method gasCost*(opcode: Opcode): Op {.base.} =
  raise newException(ValueError, "Must be implemented by subclasses")

method logger*(opcode: Opcode): Logger =
  logging.getLogger(&"vm.logic.call.{$opcode.kind}")

# TODO: not extremely happy with the method approach, maybe optimize
# a bit the run, so we directly replace it with handler's body
macro newOpcode*(kind: untyped, gasCost: untyped, handler: untyped): untyped =
  # newOpcode(Op.Mul, GAS_LOW, mul)
  let name = ident(&"Opcode{kind[1].repr}")
  let computation = ident("computation")
  result = quote:
    type
      `name`* = ref object of Opcode

    method kind*(opcode: `name`): Op =
      `kind`

    method gasCost*(opcode: `name`): Int256 =
      `gasCost`

  var code: NimNode
  if handler.kind != nnkStmtList:
    code = quote:
      method `run`*(opcode: `name`, `computation`: var BaseComputation) =
        `computation`.gasMeter.consumeGas(`gasCost`, reason = $`kind`)
        `handler`(`computation`)
  else:
    code = quote:
      method `run*`(opcode: `name`, `computation`: var BaseComputation) =
        `computation`.gasMeter.consumeGas(`gasCost`, reason = $`kind`)
        `handler`
  
  result.add(code)
  echo result.repr
