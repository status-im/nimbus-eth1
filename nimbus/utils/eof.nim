# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.


# https://eips.ethereum.org/EIPS/eip-3540
# EIP-3540: EOF - EVM Object Format v1

import
  std/strutils,
  stew/[results, byteutils, endians2]

type
  Blob = seq[byte]

  Container* = object
    types*: seq[FunctionMetaData]
    code*: seq[Blob]
    data*: Blob
    size*: int

  FunctionMetaData* = object
    input*: uint8
    output*: uint8
    maxStackHeight*: uint16

  Section = object
    kind: uint8
    size: uint16

  SectionList = object
    kind: uint8
    list: seq[uint16]

  EOFV1ErrorKind* = enum
    ErrNoEOFErr
    ErrUnexpectedEOF          = "unexpected End of Data"
    ErrInvalidMagic           = "invalid magic"
    ErrInvalidVersion         = "invalid version"
    ErrMissingTypeHeader      = "missing type header"
    ErrInvalidTypeSize        = "invalid type section size"
    ErrMissingCodeHeader      = "missing code header"
    ErrInvalidCodeHeader      = "invalid code header"
    ErrInvalidCodeSize        = "invalid code size"
    ErrMissingDataHeader      = "missing data header"
    ErrMissingTerminator      = "missing header terminator"
    ErrTooManyInputs          = "invalid type content, too many inputs"
    ErrTooManyOutputs         = "invalid type content, too many inputs"
    ErrInvalidSection0Type    = "invalid section 0 type, input and output should be zero"
    ErrTooLargeMaxStackHeight = "invalid type content, max stack height exceeds limit"
    ErrInvalidContainerSize   = "invalid container size"

  EOFV1Error* = object
    kind*: EOFV1ErrorKind
    pos* : int
    msg* : string

const
  offsetTypesKind = 3
  offsetCodeKind  = 6

  kindTypes = 1.uint8
  kindCode  = 2.uint8
  kindData  = 3.uint8

  eofFormatByte = 0xef.byte
  eof1Version   = 1.byte
  eofMagicLen   = 2
  eofMagic0     = 0xef.byte
  eofMagic1     = 0x00.byte

  maxInputItems  = 127
  maxOutputItems = 127
  maxStackHeight = 1023

proc toString*(p: EOFV1Error): string =
  if p.msg.len == 0:
    return "$1 at position $2" % [$p.kind, $p.pos]
  "$1 at position $2, $3" % [$p.kind, $p.pos, p.msg]

proc eofErr*(kind: EOFV1ErrorKind, pos: int): EOFV1Error =
  EOFV1Error(kind: kind, pos: pos)

proc eofErr*(kind: EOFV1ErrorKind, pos: int, msg: string): EOFV1Error =
  EOFV1Error(kind: kind, pos: pos, msg: msg)

# HasEOFByte returns true if code starts with 0xEF byte
func hasEOFByte*(code: openArray[byte]): bool =
  code.len != 0 and code[0] == eofFormatByte

# hasEOFMagic returns true if code starts with magic defined by EIP-3540
func hasEOFMagic*(code: openArray[byte]): bool =
  eofMagicLen <= code.len and
    eofMagic0 == code[0] and
    eofMagic1 == code[1]

# isEOFVersion1 returns true if the code's version byte equals eof1Version. It
# does not verify the EOF magic is valid.
func isEOFVersion1(code: openArray[byte]): bool =
  eofMagicLen < code.len and
    code[2] == eof1Version

# parseSection decodes a (kind, size) pair from an EOF header.
func parseSection(s: var Section, b: openArray[byte], idx: int): Result[void, EOFV1Error] =
  if idx+3 > b.len:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  s = Section(
    kind: uint8(b[idx]),
    size: uint16.frombytesBE(toOpenArray(b, idx+1, idx+1+2-1))
  )

  ok()

# parseList decodes a list of uint16..
func parseList(s: var SectionList, b: openArray[byte], idx: int): Result[void, EOFV1Error] =
  if b.len < idx+2:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  let count = frombytesBE(uint16, toOpenArray(b, idx, idx+2-1)).int
  if b.len < idx+2+count*2:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  s.list = newSeq[uint16](count)
  for i in 0..<count:
    let z = idx+2+2*i
    s.list[i] = frombytesBE(uint16, toOpenArray(b, z, z+2-1))

  ok()

# parseSectionList decodes a (kind, len, []codeSize) section list from an EOF
# header.
func parseSectionList(s: var SectionList, b: openArray[byte], idx: int): Result[void, EOFV1Error] =
  if idx >= b.len:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  s.kind = b[idx].uint8
  let res = parseList(s, b, idx+1)
  if res.isErr:
    return res

  ok()

func size(s: SectionList): int =
  for x in s.list:
    result += x.int

# decodes an EOF container.
proc decode*(c: var Container, b: openArray[byte]): Result[void, EOFV1Error] =
  if b.len < eofMagicLen:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  if not b.hasEOFMagic:
    let z = min(2, b.len)
    return err(eofErr(ErrInvalidMagic,
      0, "have 0x$1, want 0xEF00" % [toOpenArray(b, 0, z-1).toHex]))

  if not b.isEOFVersion1:
    var have = "<nil>"
    if b.len >= 3:
      have = $(b[2].int)
    return err(eofErr(ErrInvalidVersion,
      2, "have $1, want $2" % [have, $(eof1Version.int)]))

  # Parse type section header.
  var types: Section
  var res = types.parseSection(b, offsetTypesKind)
  if res.isErr:
    return res

  if types.kind != kindTypes:
    return err(eofErr(ErrMissingTypeHeader,
      offsetTypesKind,
      "found section kind $1 instead" % [toHex(types.kind.int, 2)]))

  if types.size < 4 or ((types.size mod 4) != 0):
    return err(eofErr(ErrInvalidTypeSize,
      offsetTypesKind+1,
      "type section size must be divisible by 4: have " & $types.size))

  let typesSize = types.size.int div 4
  if typesSize > 1024:
    return err(eofErr(ErrInvalidTypeSize,
      offsetTypesKind+1,
      "type section must not exceed 4*1024: have " & $(typesSize*4)))

  # Parse code section header.
  var code: SectionList
  res = code.parseSectionList(b, offsetCodeKind)
  if res.isErr:
    return res

  if code.kind != kindCode:
    return err(eofErr(ErrMissingCodeHeader,
      offsetCodeKind, "found section kind $1 instead" %
        [toHex(code.kind.int, 2)]))

  if code.list.len != typesSize:
    return err(eofErr(ErrInvalidCodeSize,
      offsetCodeKind+1,
        "mismatch of code sections count and type signatures: types $1, code $2" %
          [$typessize, $code.list.len]))

  # Parse data section header.
  let offsetDataKind = offsetCodeKind + 2 + 2*code.list.len + 1
  var data: Section
  res = data.parseSection(b, offsetDataKind)
  if res.isErr:
    return res

  if data.kind != kindData:
    return err(eofErr(ErrMissingDataHeader,
      offsetDataKind, "found section kind $1 instead" %
        [toHex(data.kind.int, 2)]))

  # Check for terminator.
  let offsetTerminator = offsetDataKind + 3
  if b.len <= offsetTerminator:
    return err(eofErr(ErrUnexpectedEOF, b.len))

  if b[offsetTerminator] != 0:
    return err(eofErr(ErrMissingTerminator,
      offsetTerminator,
      "have " & $(b[offsetTerminator].int)))

  # Verify overall container size.
  c.size = offsetTerminator + types.size.int + code.size + data.size.int + 1
  if b.len != c.size:
    return err(eofErr(ErrInvalidContainerSize, 0,
      "have $1, want $2" %
        [$b.len, $c.size]))

  # Parse types section.
  var idx = offsetTerminator + 1
  c.types = @[] # for testing purpose
  for i in 0 ..< typesSize:
    let z = idx+i*4
    let sig = FunctionMetadata(
      input:          b[z],
      output:         b[z+1],
      maxStackHeight: uint16.fromBytesBE(toOpenArray(b, z+2, z+4-1))
    )

    if sig.input > maxInputItems:
      return err(eofErr(ErrTooManyInputs, idx+i*4,
        "for section $1, have $2" %
          [$i, $sig.input.int]))

    if sig.output > maxOutputItems:
      return err(eofErr(ErrTooManyOutputs, idx+i*4+1,
        "for section $1, have $2" %
          [$i, $sig.output.int]))

    if sig.maxStackHeight > maxStackHeight:
      return err(eofErr(ErrTooLargeMaxStackHeight, idx+i*4+2,
        "for section $1, have $2" %
          [$i, $sig.maxStackHeight]))

    c.types.add(sig)

  if c.types[0].input != 0 or c.types[0].output != 0:
    return err(eofErr(ErrInvalidSection0Type, idx,
      "have $1, $2" %
        [$c.types[0].input.int, $c.types[0].output.int]))

  # Parse code sections.
  idx += types.size.int
  c.code = newSeq[Blob](code.list.len)
  for i, size in code.list:
    if size == 0:
      return err(eofErr(ErrInvalidCodeSize,
        offsetCodeKind+2+i*2,
        "invalid code section $1: size must not be 0" % [$i]))

    c.code[i] = @b[idx..<idx+size.int]
    idx += size.int

  # Parse data section.
  c.data = @b[idx..<idx+data.size.int]
  ok()

proc sum(codeList: seq[Blob]): int =
  for code in codeList:
    result += code.len

# encodes an EOF container into binary format.
proc encode*(c: Container): seq[byte] =
  # calculate container length
  var size = 13           # prefix to terminator
  size += c.code.len * 2  # code section size len
  size += c.types.len * 4 # type section content len
  size += c.code.sum      # code section content len
  size += c.data.len      # data section content len

  # Build EOF prefix.
  result = newSeqOfCap[byte](size)
  result.add eofMagic0
  result.add eofMagic1
  result.add eof1Version

  # Write type headers.
  result.add kindTypes
  result.add toBytesBE(uint16(c.types.len*4))

  # Write code section header.
  result.add kindCode
  result.add toBytesBE(uint16(c.code.len))
  for code in c.code:
    result.add toBytesBE(uint16(code.len))

  # Write data section header.
  result.add kindData
  result.add toBytesBE(uint16(c.data.len))
  result.add 0.byte # terminator

  # Write type section contents.
  for x in c.types:
    result.add x.input
    result.add x.output
    result.add toBytesBE(x.maxStackHeight)

  # Write code section contents.
  for code in c.code:
    result.add code

  # Write data section contents.
  result.add c.data
  doAssert(size == result.len)
