# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ./eof_utils,
  std/intsets,
  results

func validateCode(code: openArray[byte]): Result[void, string] =
  # Note that EOF1 already asserts this with the code section requirements
  assert code.len > 0

  var
    pos = 0
    rjumpdests = initIntSet()
    immediates = initIntSet()

  while pos < code.len:
    # Ensure the opcode is valid
    let opcode = code[pos]
    inc pos
    if opcode notin ValidOpcodes:
      return err("undefined instruction")

    let pc_post_instruction = pos + ImmediateSizes[opcode].int

    if opcode in [OP_RJUMP, OP_RJUMPI]:
      if pos + 2 > code.len:
        return err("truncated relative jump offset")
      let offset = code.parseInt16(pos)

      let rjumpdest = pc_post_instruction + offset
      if rjumpdest < 0 or rjumpdest >= code.len:
        return err("relative jump destination out of bounds")

      rjumpdests.incl(rjumpdest)
    elif opcode == OP_RJUMPV:
      if pos + 1 > code.len:
        return err("truncated jump table")
      let jump_table_size = code[pos].int
      if jump_table_size == 0:
        return err("empty jump table")

      let pc_post_instruction = pos + 1 + 2 * jump_table_size
      if pc_post_instruction > code.len:
        return err("truncated jump table")

      for offset_pos in countup(pos + 1, pc_post_instruction-1, 2):
        let offset = code.parseInt16(offset_pos)

        let rjumpdest = pc_post_instruction + offset
        if rjumpdest < 0 or rjumpdest >= code.len:
          return err("relative jump destination out of bounds")
        rjumpdests.incl(rjumpdest)

    # Save immediate value positions
    for x in pos..<pc_post_instruction:
      immediates.incl(x)
    # Skip immediates
    pos = pc_post_instruction

  # Ensure last instruction's immediate doesn't go over code end
  if pos != code.len:
    return err("truncated immediate")

  # Ensure relative jump destinations don't target immediates
  if not rjumpdests.disjoint(immediates):
    return err("relative jump destination targets immediate")

  ok()
