import
  strformat, strutils, sequtils, macros,
  constants, logging, errors, opcode_values, computation, vm/stack, bigints

template run*(opcode: Opcode, computation: var BaseComputation) =
  # Hook for performing the actual VM execution
  computation.gasMeter.consumeGas(opcode.gasCost, reason = $opcode.kind)
  opcode.runLogic(computation)

method logger*(opcode: Opcode): Logger =
  logging.getLogger(&"vm.opcode.{opcode.kind}")

proc newOpcode*(kind: Op, gasCost: Int256, logic: proc(computation: var BaseComputation)): Opcode =
  Opcode(kind: kind, gasCost: gasCost, runLogic: logic)


method `$`*(opcode: Opcode): string =
  &"{opcode.kind}(0x{opcode.kind.int.toHex(2)}: {opcode.gasCost})"

macro initOpcodes*(spec: untyped): untyped =
  var value = ident("value")
  result = quote:
    block:
      var `value` = initTable[Op, Opcode]()

  for child in spec:
    let op = child[0]
    let gasCost = child[1][0][0]
    let handler = child[1][0][1]
    var opcode = quote:
      `value`[`op`] = newOpcode(`op`, `gasCost`, `handler`)
    result[1].add(opcode)
  
  result[1].add(value)

