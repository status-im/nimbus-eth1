# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stew/byteutils, results, ./interpreter/op_codes

export results

type CodeBytesRef* = ref object
  ## Code buffer that caches invalid jump positions used for verifying jump
  ## destinations - `bytes` is immutable once instances is created while
  ## `invalidPositions` will be built up on demand
  bytes: seq[byte]
  invalidPositions: seq[byte] # bit seq of invalid jump positions
  processed: int

template bitpos(pos: int): (int, byte) =
  (pos shr 3, 1'u8 shl (pos and 0x07))

func init*(T: type CodeBytesRef, bytes: sink seq[byte]): CodeBytesRef =
  let ip = newSeq[byte]((bytes.len + 7) div 8)
  CodeBytesRef(bytes: move(bytes), invalidPositions: ip)

func init*(T: type CodeBytesRef, bytes: openArray[byte]): CodeBytesRef =
  CodeBytesRef.init(@bytes)

func init*(T: type CodeBytesRef, bytes: openArray[char]): CodeBytesRef =
  CodeBytesRef.init(bytes.toOpenArrayByte(0, bytes.high()))

func fromHex*(T: type CodeBytesRef, hex: openArray[char]): Opt[CodeBytesRef] =
  try:
    Opt.some(CodeBytesRef.init(hexToSeqByte(hex)))
  except ValueError:
    Opt.none(CodeBytesRef)

func invalidPosition(c: CodeBytesRef, pos: int): bool =
  let (bpos, bbit) = bitpos(pos)
  (c.invalidPositions[bpos] and bbit) > 0

func bytes*(c: CodeBytesRef): lent seq[byte] =
  c[].bytes

func len*(c: CodeBytesRef): int =
  len(c.bytes)

func isValidOpcode*(c: CodeBytesRef, position: int): bool =
  if position >= len(c):
    false
  elif c.invalidPosition(position):
    false
  elif position <= c.processed:
    true
  else:
    var i = c.processed
    while i <= position:
      var opcode = Op(c.bytes[i])
      if opcode >= Op.Push1 and opcode <= Op.Push32:
        var leftBound = (i + 1)
        var rightBound = leftBound + (opcode.int - 95)
        for z in leftBound ..< rightBound:
          let (bpos, bbit) = bitpos(z)
          c.invalidPositions[bpos] = c.invalidPositions[bpos] or bbit
        i = rightBound
      else:
        i += 1
    c.processed = i - 1

    not c.invalidPosition(position)

func `==`*(a: CodeBytesRef, b: openArray[byte]): bool =
  a.bytes == b
