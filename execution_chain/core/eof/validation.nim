import
  std/sequtils,
  results,
  ./eof_utils

func validateEof(code: openArray[byte]): Result[EOFHeader, string] =
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
  h.numCodeSections = p.u16
  if not (h.numCodeSections >= 1 and h.numCodeSections <= 0x400):
    return err("num code sections out of range")

  if h.numCodeSections != h.typesSize div 4:
    return err("num code sections not equal to fourth of types size")

  ? p.expectLen(h.numCodeSections * 2 + 4)

  for _ in 0..<h.numCodeSections:
    let codeSize = p.u16
    if not (codeSize >= 1 and codeSize <= 0xffff):
      return err("code size out of range")
    h.codeSizes.add codeSize

  let sectionId = p.u8
  if sectionId == KIND_CONTAINER:
    h.numContainerSections = p.u16
    if not (h.numContainerSections >= 1 and h.numContainerSections <= 0x100):
      return err("num container sections out of range")
    ? p.expectLen(h.numContainerSections * 2 + 4)

    for _ in 0..<h.numContainerSections:
      let containerSize = p.u16
      if not (containerSize >= 1 and containerSize <= 0xffff):
        return err("container size out of range")
      h.containerSizes.add containerSize
  else:
    dec p.pos

  ? p.expectSection(KIND_DATA)
  h.dataSize = p.u16

  ? p.expectSection(TERMINATOR)

  let totalLen = if h.numContainerSections == 0:
                   13 + 2*h.numCodeSections +
                   h.typesSize +
                   h.dataSize +
                   h.codeSizes.foldl(a + b)
                 else:
                   16 + 2*h.numCodeSections +
                   h.typesSize +
                   h.dataSize +
                   h.codeSizes.foldl(a + b) +
                   2*h.numContainerSections +
                   h.containerSizes.foldl(a + b)

  if totalLen != code.len:
    return err("container size not equal to sum of section sizes")

  ok(h)
