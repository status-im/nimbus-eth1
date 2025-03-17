# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, deques],
  results,
  ./eip4750,
  ./eip5450_table,
  ./eof_utils,
  ../../evm/interpreter/codes

func validateFunction*(funcId: int,
                       code: openArray[byte],
                       types: openArray[FunctionType] = [ZeroFunctionType]):
                         Result[int, string] =
  assert funcId >= 0
  assert funcId < types.len
  assert types[funcId].inputs >= 0
  assert types[funcId].outputs >= 0

  ?validateCodeSection(funcId, code, types)

  var
    stackHeights: Table[int, int]
    startStackHeight = types[funcId].inputs
    maxStackHeight = startStackHeight

    # queue of instructions to analyze, list of (pos, stackHeight) pairs
    worklist = [(0, startStackHeight)].toDeque

  while worklist.len > 0:
    var (pos, stackHeight) = worklist.popFirst
    while true:
      # Assuming code ends with a terminating instruction due to previous validation in validate_code_section()
      assert pos < code.len, "code is invalid"
      let
        op = code[pos]
        info = InstrTable[op.Op]

      # Check if stack height (type arity) at given position is the same
      # for all control flow paths reaching this position.
      if pos in stackHeights:
        if stackHeight != stackHeights[pos]:
          return err("stack height mismatch for different paths")
        else:
          break
      else:
        stackHeights[pos] = stackHeight


      var
        stackHeightRequired = info.stackHeightRequired
        stackHeightChange = info.stackHeightChange

      if op == OP_CALLF:
        let calledFuncId = code.parseUint16(pos + 1)
        # Assuming calledFuncId is valid due to previous validation in validate_code_section()
        stackHeightRequired += types[calledFuncId].inputs
        stackHeightChange += types[calledFuncId].outputs - types[calledFuncId].inputs

      # Detect stack underflow
      if stackHeight < stackHeightRequired:
        return err("stack underflow")

      stackHeight += stackHeightChange
      maxStackHeight = max(maxStackHeight, stackHeight)

      # Handle jumps
      if op == OP_RJUMP:
        let offset = code.parseInt16(pos + 1)
        pos += info.immediateSize + 1 + offset  # pos is valid for validated code.

      elif op == OP_RJUMPI:
        let offset = code.parseInt16(pos + 1)
        # Save true branch for later and continue to False branch.
        worklist.addLast((pos + 3 + offset, stackHeight))
        pos += info.immediateSize + 1

      elif info.isTerminating:
        let expectedHeight = if op == OP_RETF: types[funcId].outputs else: 0
        if stackHeight != expectedHeight:
          return err("non-empty stack on terminating instruction")
        break

      else:
        pos += info.immediateSize + 1


  if maxStackHeight >= 1023:
    return err("max stack above limit")

  ok(maxStackHeight)
