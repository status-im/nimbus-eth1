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
  std/[sequtils, intsets],
  results,
  ./eof_utils

func validateEof*(code: openArray[byte]): Result[void, string] =
  # Check version
  if code.len < 3 or code[2] != VERSION:
    return err("invalid version")

  # Process section headers
  var
    pos = 3
    codeSectionSize: seq[int]
    dataSectionSize = Opt.none(int)
    typeSectionSize = Opt.none(int)

  while true:
    # Terminator not found
    if pos >= code.len:
      return err("no section terminator")

    let sectionId = code[pos]
    inc pos
    if sectionId == TERMINATOR:
      break

    # Disallow unknown sections
    if sectionId notin [CODE, DATA, TYPE]:
      return err("invalid section id")

    # Data section preceding code section (i.e. code section following data section)
    if sectionId == CODE and dataSectionSize.isSome:
      return err("data section preceding code section")

    # Code section or data section preceding type section
    if sectionId == TYPE and (codeSectionSize.len > 0 or dataSectionSize.isSome):
      return err("code or data section preceding type section")

    # Multiple type or data sections
    if sectionId == TYPE and typeSectionSize.isSome:
      return err("multiple type sections")
    if sectionId == DATA and dataSectionSize.isSome:
      return err("multiple data sections")

    # Truncated section size
    if (pos + 1) >= code.len:
      return err("truncated section size")

    let sectionSize = code.parseUint16(pos)
    if sectionId == DATA:
      dataSectionSize = Opt.some(sectionSize)
    elif sectionId == TYPE:
      typeSectionSize = Opt.some(sectionSize)
    else:
      codeSectionSize.add sectionSize

    inc(pos, 2)

    # Empty section
    if sectionSize == 0:
      return err("empty section")

  # Code section cannot be absent
  if codeSectionSize.len == 0:
    return err("no code section")

  # Not more than 1024 code sections
  if codeSectionSize.len > 1024:
    return err("more than 1024 code sections")

  # Type section can be absent only if single code section is present
  if typeSectionSize.isNone and codeSectionSize.len != 1:
    return err("no obligatory type section")

  # Type section, if present, has size corresponding to number of code sections
  if typeSectionSize.isSome and typeSectionSize.value != codeSectionSize.len * 2:
    return err("invalid type section size")

  # The entire container must be scanned
  if code.len != (pos + typeSectionSize.get(0) + codeSectionSize.foldl(a + b) + dataSectionSize.get(0)):
    return err("container size not equal to sum of section sizes")

  # First type section, if present, has 0 inputs and 0 outputs
  if typeSectionSize.isSome and (code[pos] != 0 or code[pos + 1] != 0):
    return err("invalid type of section 0")

  ok()
#[
# Raises ValidationException on invalid code
func validateCodeSection*(funcId: int,
                         code: openArray[byte],
                         types: openArray[FunctionType] = [ZeroFunctionType]):
                           Result[void, string] =
  # Note that EOF1 already asserts this with the code section requirements
  assert code.len > 0
  assert funcId < types.len

  var
    pos = 0
    opcode = 0.byte
    rjumpdests = initIntSet()
    immediates = initIntSet()

  while pos < code.len:
    # Ensure the opcode is valid
    opcode = code[pos]
    inc pos
    if opcode notin ValidOpcodes:
      return err("undefined instruction")

    var pcPostInstruction = pos + ImmediateSizes[opcode].int

    if opcode == OP_RJUMP or opcode == OP_RJUMPI:
      if pos + 2 > code.len:
        return err("truncated relative jump offset")
      let offset = code.parseInt16(pos)

      let rjumpdest = pos + 2 + offset
      if rjumpdest < 0 or rjumpdest >= code.len:
        return err("relative jump destination out of bounds")

      rjumpdests.incl(rjumpdest)

    elif opcode == OP_RJUMPV:
      if pos + 1 > code.len:
        return err("truncated jump table")
      let jumpTableSize = code[pos].int
      if jumpTableSize == 0:
        return err("empty jump table")

      pcPostInstruction = pos + 1 + 2 * jumpTableSize
      if pcPostInstruction > code.len:
        return err("truncated jump table")

      for offsetPos in countup(pos + 1, pcPostInstruction-1, 2):
        let offset = code.parseInt16(offsetPos)

        let rjumpdest = pcPostInstruction + offset
        if rjumpdest < 0 or rjumpdest >= code.len:
          return err("relative jump destination out of bounds")

        rjumpdests.incl(rjumpdest)

    elif opcode == OP_CALLF:
      if pos + 2 > code.len:
        return err("truncated CALLF immediate")
      let sectionId = code.parseUint16(pos)

      if sectionId >= types.len:
        return err("invalid section id")

    elif opcode == OP_JUMPF:
      if pos + 2 > code.len:
        return err("truncated JUMPF immediate")
      let sectionId = code.parseUint16(pos)

      if sectionId >= types.len:
        return err("invalid section id")

      if types[sectionId].outputs != types[funcId].outputs:
        return err("incompatible function type for JUMPF")

    # Save immediate value positions
    for x in pos..<pcPostInstruction:
      immediates.incl(x)

    # Skip immediates
    pos = pcPostInstruction

  # Ensure last opcode's immediate doesn't go over code end
  if pos != code.len:
    return err("truncated immediate")

  # opcode is the *last opcode*
  if opcode notin TerminatingOpcodes:
    return err("no terminating instruction")

  # Ensure relative jump destinations don't target immediates
  if not rjumpdests.disjoint(immediates):
    return err("relative jump destination targets immediate")

  ok()
]#