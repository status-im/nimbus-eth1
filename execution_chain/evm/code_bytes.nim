# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/byteutils,
  stew/assign2,
  results,
  ./interpreter/op_codes

export results

type CodeBytesRef* = ref object
  ## Code buffer that caches invalid jump positions used for verifying jump
  ## destinations - `bytes` is immutable once instances is created while
  ## `invalidPositions` will be built up on demand
  bytes: seq[byte]
  invalidPositions: seq[byte] # bit seq of invalid jump positions
  processed: int
  persisted*: bool ## This code stream has been persisted to the database

template bitpos(pos: int): (int, byte) =
  (pos shr 3, 1'u8 shl (pos and 0x07))

func init*(
    T: type CodeBytesRef, bytes: sink seq[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef(bytes: move(bytes), persisted: persisted)

func init*(
    T: type CodeBytesRef, bytes: openArray[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef.init(@bytes, persisted = persisted)

func init*(T: type CodeBytesRef, bytes: openArray[char]): CodeBytesRef =
  CodeBytesRef.init(bytes.toOpenArrayByte(0, bytes.high()))

func fromHex*(T: type CodeBytesRef, hex: string): Opt[CodeBytesRef] =
  try:
    Opt.some(CodeBytesRef.init(hexToSeqByte(hex)))
  except ValueError:
    Opt.none(CodeBytesRef)

func bytes*(c: CodeBytesRef): lent seq[byte] {.inline.} =
  c[].bytes

template len*(c: CodeBytesRef): int =
  len(bytes(c))

# Bounds checking done manually - this is a hotspot in the EVM
{.push checks: off.}

template invalidPosition(c: CodeBytesRef, pos: int): bool =
  let (bpos, bbit) = bitpos(pos)
  (c.invalidPositions[bpos] and bbit) > 0

func isPushOpcode(b: byte): bool =
  ## PUSH1..PUSH32 (0x60..0x7f) are exactly the bytes whose top three bits
  ## are `0b011`.
  (b and 0xe0'u8) == 0x60'u8

func hasPushOpcode(word: uint64): bool =
  ## Whether any of the eight bytes packed into `word` is a PUSH opcode.
  ##
  ## Applying the `isPushOpcode` mask-and-compare to all eight bytes at once
  ## leaves a zero byte wherever a PUSH was, turning the question into "is any
  ## byte zero". That is the usual SWAR test: `(v - 1) and not v` keeps the
  ## high bit of a byte only when that byte was zero. Masking first leaves
  ## every byte a multiple of 0x20, so only a zero byte can borrow into its
  ## neighbour and the test yields no false positives.
  const
    topThreeBits = 0xe0e0e0e0e0e0e0e0'u64
    pushBits = 0x6060606060606060'u64
    lowBitOfEach = 0x0101010101010101'u64
    highBitOfEach = 0x8080808080808080'u64
  let v = (word and topThreeBits) xor pushBits
  ((v - lowBitOfEach) and not v and highBitOfEach) != 0

func skipToNextPush(bytes: openArray[byte], start: int): int =
  ## Index of the first PUSH opcode at or after `start`, or `bytes.len` if
  ## there is none.
  ##
  ## The scan below only has work to do at a PUSH: every other opcode is one
  ## byte wide and marks nothing. So a run of non-PUSH bytes can be stepped
  ## over eight at a time instead of one per loop iteration, which is what
  ## makes large contracts padded with plain opcodes cheap to scan.
  var i = start
  while i + 8 <= bytes.len:
    var word: uint64
    copyMem(addr word, unsafeAddr bytes[i], 8)
    if hasPushOpcode(word):
      break # a PUSH lies in these eight bytes; the byte loop finds which
    i += 8

  while i < bytes.len and not isPushOpcode(bytes[i]):
    i += 1
  i

func isValidOpcode*(c: CodeBytesRef, position: int): bool =
  if position >= len(c):
    return false

  if c.invalidPositions.len == 0:
    c.invalidPositions.setLen((len(c) + 7) div 8)

  if c.invalidPosition(position):
    false
  elif position <= c.processed:
    true
  else:
    var i = c.processed
    while i <= position:
      var opcode = Op(c.bytes[i])
      if opcode >= Op.Push1 and opcode <= Op.Push32:
        var leftBound = (i + 1)
        var rightBound = min(leftBound + (opcode.int - 95), c.bytes.len)
        for z in leftBound ..< rightBound:
          let (bpos, bbit) = bitpos(z)
          c.invalidPositions[bpos] = c.invalidPositions[bpos] or bbit
        i = rightBound
      else:
        # Nothing to mark for this byte, nor for any byte before the next
        # PUSH, so step over the whole run in one go
        i = skipToNextPush(c.bytes, i + 1)
    c.processed = i - 1

    not c.invalidPosition(position)

{.pop.}

template `==`*(a: CodeBytesRef, b: openArray[byte]): bool =
  bytes(a) == b

template hasPrefix*(a: CodeBytesRef, b: openArray[byte]): bool =
  let
    code = a
    prefixLen = b.len
  prefixLen <= len(code) and bytes(code).toOpenArray(0, prefixLen - 1) == b

template slice*[N: static[int]](a: CodeBytesRef, b, c: int): array[N, byte] =
  var r: array[N, byte]
  assign(r, bytes(a).toOpenArray(b, c))
  r
