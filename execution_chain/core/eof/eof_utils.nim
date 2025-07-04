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
  stew/bitseqs,
  stew/endians2,
  stew/ptrops,
  results,
  ./eof_types

export
  bitseqs


#[func setRange*(a: var BitArray, s: Natural, ss: Natural) =
  for x in s..ss:
    a.setBit x

func setBit*(a: var BitArray, r: openArray[Natural]) =
  for x in r:
    a.setBit x

template contains*(a: BitArray, pos: Natural): bool =
  a[pos]

# The ranges below are as specified in the Yellow Paper.
const
  OP_RJUMP*     = 0xe0.byte
  OP_RJUMPI*    = 0xe1.byte
  OP_RJUMPV*    = 0xe2.byte
  OP_CALLF*     = 0xe3.byte
  OP_RETF*      = 0xe4.byte
  OP_JUMPF*     = 0xe5.byte
  OP_EOFCREATE* = 0xec.byte
  OP_RETURNCODE*= 0xee.byte

  ValidOpcodes* =
    block:
      var bits: BitArray[256]
      bits.setRange(0x00, 0x0b)
      bits.setRange(0x10, 0x1d)
      bits.setBit(0x20)
      bits.setRange(0x30, 0x3f)
      bits.setRange(0x40, 0x4a)
      bits.setRange(0x50, 0x55)
      bits.setRange(0x58, 0x5d)
      bits.setRange(0x60, 0x6f)
      bits.setRange(0x70, 0x7f)
      bits.setRange(0x80, 0x8f)
      bits.setRange(0x90, 0x9f)
      bits.setRange(0xa0, 0xa4)
      bits.setRange(0xd0, 0xd3)
      bits.setRange(0xe6, 0xe8)
      bits.setRange(0xec, 0xee)


      # Note: 0xfe is considered assigned.

      bits
]#

type
  EOFParser* = object
    codeView: CodeView
    pos*: int
    codeLen: int

const
  MAGIC* = [0xEF.byte, 0x00.byte]
  VERSION* = 0x01.byte
  TERMINATOR*     = 0x00.byte
  KIND_TYPES*     = 0x01.byte
  KIND_CODE*      = 0x02.byte
  KIND_CONTAINER* = 0x03.byte
  KIND_DATA*      = 0x04.byte

func initEOFParser*(code: openArray[byte]): EOFParser =
  EOFParser(
    codeView: cast[CodeView](code[0].addr),
    pos: 0,
    codeLen: code.len,
  )

func u16*(p: var EOFParser): int =
  result = fromBytesBE(uint16, makeOpenArray(addr p.codeView[p.pos], byte, 2)).int
  inc(p.pos, 2)

func i16*(p: var EOFParser): int =
  let val = fromBytesBE(uint16, makeOpenArray(addr p.codeView[p.pos], byte, 2))
  inc(p.pos, 2)
  cast[int16](val).int

func u8*(p: var EOFParser): byte =
  result = p.codeView[p.pos]
  inc p.pos

func expectSection*(p: var EOFParser, id: byte): Result[void, string] =
  let sectionId = p.u8
  if sectionId != id:
    return err("expect section id: " & $(id.int))
  ok()

func expectLen*(p: EOFParser, len: int): Result[void, string] =
  if p.pos + len >= p.codeLen:
    return err("no section terminator")
  ok()

func codeView*(p: var EOFParser, len: int): CodeView =
  result = cast[CodeView](p.codeView[p.pos].addr)
  inc(p.pos, len)

func remainingSize*(p: EOFParser): int =
  p.codeLen - p.pos
