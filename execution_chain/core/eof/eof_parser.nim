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
  std/sequtils,
  results,
  ./eof_utils,
  ./eof_types

func eofParseHeader*(code: openArray[byte]): Result[EOFHeader, string] =
  # TODO: the total size of a container must not exceed MAX_INITCODE_SIZE

  if code.len < 15:
    return err("header size is less than 15 bytes")

  if code[2] != VERSION:
    return err("invalid version")

  var
    h: EOFHeader
    p = initEOFParser(code.toOpenArray(3, code.len-1))

  ? p.expectSection(KIND_TYPES)
  h.typesSize = p.u16
  if not (h.typesSize >= 4 and h.typesSize <= 0x1000):
    return err("types size out of range")

  if h.typesSize mod 4 != 0:
    return err("types size must divisible by 4")

  ? p.expectSection(KIND_CODE)
  let numCodeSections = p.u16
  if not (numCodeSections >= 1 and numCodeSections <= 0x400):
    return err("num code sections out of range")

  if numCodeSections != h.typesSize div 4:
    return err("num code sections not equal to fourth of types size")

  ? p.expectLen(numCodeSections * 2 + 4)

  for _ in 0..<numCodeSections:
    let codeSize = p.u16
    if not (codeSize >= 1 and codeSize <= 0xffff):
      return err("code size out of range")
    h.codeSizes.add codeSize

  let sectionId = p.u8
  var numContainerSections: int
  if sectionId == KIND_CONTAINER:
    numContainerSections = p.u16
    if not (numContainerSections >= 1 and numContainerSections <= 0x100):
      return err("num container sections out of range")
    ? p.expectLen(numContainerSections * 2 + 4)

    for _ in 0..<numContainerSections:
      let containerSize = p.u16
      if not (containerSize >= 1 and containerSize <= 0xffff):
        return err("container size out of range")
      h.containerSizes.add containerSize
  else:
    dec p.pos

  ? p.expectLen(4) # KIND_DATA(1) + DATA_SIZE(2) + TERMINATOR(1)
  ? p.expectSection(KIND_DATA)
  h.dataSize = p.u16

  ? p.expectSection(TERMINATOR)

  let totalLen = if numContainerSections == 0:
                   13 + 2*numCodeSections +
                   h.typesSize +
                   h.dataSize +
                   h.codeSizes.foldl(a + b)
                 else:
                   16 + 2*numCodeSections +
                   h.typesSize +
                   h.dataSize +
                   h.codeSizes.foldl(a + b) +
                   2*numContainerSections +
                   h.containerSizes.foldl(a + b)

  if totalLen != code.len:
    return err("container size not equal to sum of section sizes")

  ok(move(h))

func eofParseBody*(code: openArray[byte], h: EOFHeader): Result[EOFBody, string] =
  # Total code length should have been validated by eofParseHeader,
  # and we don't have to do it again here.

  let
    headerSize = h.size()
    numTypes  = h.typesSize div 4

  var
    p = initEOFParser(code.toOpenArray(headerSize, code.len-1))
    body: EOFBody

  body.types = newSeqOfCap[EOFType](numTypes)
  body.codes = newSeqOfCap[CodeView](h.codeSizes.len)
  body.containers = newSeqOfCap[CodeView](h.containerSizes.len)

  for _ in 0..<numTypes:
    let inputs = p.u8
    if inputs > 0x7F:
      return err("Invalid inputs value")

    let outputs = p.u8
    if outputs > 0x80:
      return err("Invalid outputs value")

    let maxStackIncrease = p.u16
    if maxStackIncrease > 0x03FF:
      return err("Invalid maxStackIncrease value")

    body.types.add EOFType(
      inputs: inputs,
      outputs: outputs,
      maxStackIncrease: maxStackIncrease.uint16
    )

  for c in h.codeSizes:
    body.codes.add p.codeView(c)

  for c in h.containerSizes:
    body.containers.add p.codeView(c)

  body.data = p.codeView(p.remainingSize)

  ok(move(body))
