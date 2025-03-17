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
  ../../evm/code_bytes,
  results
  
# Determines if code is in EOF format of any version.
func isEof(code: CodeBytesRef): bool =
  code.hasPrefix(MAGIC)

# Raises ValidationException on invalid code
func validateEof(code: openArray[byte]): Result[void, string] =
  # Check version
  if code.len < 3 or code[2] != VERSION:
    return err("invalid version")

  # Process section headers
  var
    pos = 3
    codeSectionSize = 0
    dataSectionSize = 0

  while true:
    # Terminator not found
    if pos >= code.len:
      return err("no section terminator")

    let sectionId = code[pos]
    inc pos
    if sectionId == TERMINATOR:
      break

    # Disallow unknown sections
    if sectionId notin [CODE, DATA]:
      return err("invalid section id")

    # Data section preceding code section
    if sectionId == DATA and codeSectionSize == 0:
      return err("data section preceding code section")

    # Multiple sections with the same id
    if sectionId == DATA and dataSectionSize != 0:
      return err("multiple sections with same id")

    if sectionId == CODE and codeSectionSize != 0:
      return err("multiple sections with same id")

    # Truncated section size
    if (pos + 1) >= code.len:
      return err("truncated section size")

    let sectionSize = code.parseUint16(pos)
    if sectionId == DATA:
      dataSectionSize = sectionSize
    else:
      codeSectionSize = sectionSize

    inc(pos, 2)

    # Empty section
    if sectionSize == 0:
      return err("empty section")

  # Code section cannot be absent
  if codeSectionSize == 0:
    return err("no code section")

  # The entire container must be scanned
  if code.len != (pos + codeSectionSize + dataSectionSize):
    return err("container size not equal to sum of section sizes")

  ok()

# Validates any code
func isValidContainer(code: CodeBytesRef): bool =
  if code.isEof:
    validateEof(code.bytes).isOkOr:
      return false
  true
