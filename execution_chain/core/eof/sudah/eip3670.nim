# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  results,
  ./eof_utils

func validateInstructions(code: openArray[byte]): Result[void, string] =
  # Note that EOF1 already asserts this with the code section requirements
  assert code.len > 0

  var pos = 0
  while pos < code.len:
    # Ensure the opcode is valid
    let opcode = code[pos]
    if opcode.Natural notin ValidOpcodes:
      return err("undefined instruction")

    # Skip immediate data
    pos += 1 + ImmediateSizes[opcode].int

  # Ensure last instruction's immediate doesn't go over code end
  if pos != code.len:
    return err("truncated immediate")

  ok()
