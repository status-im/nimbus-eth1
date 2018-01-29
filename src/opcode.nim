import
  strformat, strutils, sequtils, macros,
  constants, logging, errors, opcode_values, computation, vm/stack, bigints

template run*(opcode: Opcode, computation: var BaseComputation) =
  # Hook for performing the actual VM execution
  computation.gasMeter.consumeGas(opcode.gasCost(computation), reason = $opcode.kind)
  opcode.runLogic(computation)

method logger*(opcode: Opcode): Logger =
  logging.getLogger(&"vm.opcode.{opcode.kind}")

method gasCost*(opcode: Opcode, computation: var BaseComputation): Int256 =
  if opcode.kind in VARIABLE_GAS_COST_OPS:
    opcode.gasCostHandler(computation)
  else:
    opcode.gasCostConstant

template newOpcode*(kind: Op, gasCost: Int256, logic: proc(computation: var BaseComputation)): Opcode =
  Opcode(kind: kind, gasCostConstant: gasCost, runLogic: logic)

template newOpcode*(kind: Op, gasHandler: proc(computation: var BaseComputation): Int256, logic: proc(computation: var BaseComputation)): Opcode =
  Opcode(kind: kind, gasCostHandler: gasHandler, runLogic: logic)

method `$`*(opcode: Opcode): string =
  let gasCost = if opcode.kind in VARIABLE_GAS_COST_OPS:
    "variable"
  else:
    $opcode.gasCostConstant
  &"{opcode.kind}(0x{opcode.kind.int.toHex(2)}: {gasCost})"

macro initOpcodes*(spec: untyped): untyped =
  var value = ident("value")
  result = quote:
    block:
      var `value` = initTable[Op, Opcode]()

  for child in spec:
    let op = child[0]
    let gasCost = child[1][0][0]
    let handler = child[1][0][1]
    let opcode = if gasCost.repr[0].isLowerAscii():
      quote:
        `value`[`op`] = Opcode(kind: `op`, gasCostHandler: `gasCost`, runLogic: `handler`)
    else:
      quote:
        `value`[`op`] = Opcode(kind: `op`, gasCostConstant: `gasCost`, runLogic: `handler`)
    result[1].add(opcode)
  
  result[1].add(value)

