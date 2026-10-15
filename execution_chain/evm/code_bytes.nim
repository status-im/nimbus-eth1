# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/byteutils,
  stew/assign2,
  stew/endians2,
  results,
  ./interpreter/op_codes

export results

type CodeBytesRef* = ref object
  ## Code buffer that caches the valid jump destinations - `bytes` is
  ## immutable once instances is created while `jumpdests` is either supplied
  ## at creation or computed in full on the first jump
  bytes: seq[byte]
  jumpdests: seq[byte] # bit seq of valid JUMPDEST positions
  persisted*: bool ## This code stream has been persisted to the database

template bitpos(pos: int): (int, byte) =
  (pos shr 3, 1'u8 shl (pos and 0x07))

func init*(
    T: type CodeBytesRef, bytes: sink seq[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef(bytes: move(bytes), persisted: persisted)

func init*(
    T: type CodeBytesRef,
    bytes: sink seq[byte],
    jumpdests: sink seq[byte],
    persisted = false,
): CodeBytesRef =
  ## Create a code buffer from `bytes` and the `jumpdestBitmap` of the same
  ## bytes, which is used as is
  doAssert jumpdests.len == (bytes.len + 7) div 8
  CodeBytesRef(bytes: move(bytes), jumpdests: move(jumpdests), persisted: persisted)

func initCopy*(
    T: type CodeBytesRef, bytes: seq[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef(bytes: bytes, persisted: persisted)

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

func jumpdestBits(word: uint64): byte =
  ## One bit per JUMPDEST among the eight bytes packed into `word`, lowest
  ## byte first.
  ##
  ## The xor turns every JUMPDEST into a zero byte. Adding 0x7f to the low
  ## seven bits of each byte and or-ing the byte back in sets the high bit of
  ## exactly the nonzero bytes without carrying into a neighbour, and the
  ## multiply gathers the eight remaining high bits into the top byte.
  const
    jumpdestBytes = 0x5b5b5b5b5b5b5b5b'u64
    lowSevenBits = 0x7f7f7f7f7f7f7f7f'u64
    highBitOfEach = 0x8080808080808080'u64
    gather = 0x0102040810204080'u64
  let
    v = word xor jumpdestBytes
    zeroBytes = not (((v and lowSevenBits) + lowSevenBits) or v) and highBitOfEach
  byte(((zeroBytes shr 7) * gather) shr 56)

func markPushFreeWords(
    bytes: openArray[byte], bitmap: var seq[byte], start: int
): int =
  ## Marks the JUMPDESTs of the eight-byte words from the aligned instruction
  ## start `start` up to the first word holding a PUSH, and returns where the
  ## walk resumes. Every byte of a word without a PUSH is an opcode.
  var i = start
  while i + 8 <= bytes.len:
    var word: uint64
    copyMem(addr word, unsafeAddr bytes[i], 8)
    if hasPushOpcode(word):
      break
    bitmap[i shr 3] = jumpdestBits(fromLE(word))
    i += 8
  i

func jumpdestBitmap*(bytes: openArray[byte]): seq[byte] =
  ## Bit seq of the valid jump destinations in `bytes`: the JUMPDEST opcodes
  ## that are not PUSH data
  var bitmap = newSeq[byte]((bytes.len + 7) div 8)
  var i = 0
  while i < bytes.len:
    var
      op = bytes[i]
      stop = min((i + 31) and not 7, bytes.len)
    # Runs of single-byte opcodes step `i` without depending on the loaded
    # byte, so the next load does not wait on this one. A run that reaches
    # `stop`, the first aligned position 24 bytes in, goes on a word at a time
    while not isPushOpcode(op):
      if op == byte(JumpDest):
        let (bpos, bbit) = bitpos(i)
        bitmap[bpos] = bitmap[bpos] or bbit
      i += 1
      if i >= stop:
        i = markPushFreeWords(bytes, bitmap, i)
        if i >= bytes.len:
          return bitmap
        stop = bytes.len
      op = bytes[i]
    i += op.int - 94
  bitmap

func isValidJumpdest*(c: CodeBytesRef, position: int): bool =
  if uint(position) >= uint(len(c)):
    return false

  if c.jumpdests.len == 0:
    c.jumpdests = jumpdestBitmap(c.bytes)

  let (bpos, bbit) = bitpos(position)
  (c.jumpdests[bpos] and bbit) != 0

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
