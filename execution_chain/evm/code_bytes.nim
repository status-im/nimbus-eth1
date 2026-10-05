# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  stew/byteutils,
  stew/assign2,
  results,
  ./interpreter/op_codes

from system/ansi_c import c_malloc, c_free

export results

type
  CodeBlobHeader = object
    refCount: Atomic[int]
    processed: Atomic[int]
    scanLock: Atomic[bool]
    codeLen: int

  CodeBlob* = ptr CodeBlobHeader
    ## Shared-heap code buffer: the header is followed by the code bytes and
    ## the bitmap of invalid jump positions. The code cache and every ledger
    ## that handed out a `CodeBytesRef` to the blob hold one reference each.

  CodeBytesRef* = ref object
    ## Code buffer that caches invalid jump positions used for verifying jump
    ## destinations - `bytes` is immutable once instances is created while
    ## `invalidPositions` will be built up on demand
    blob: CodeBlob
      ## When set, the code and jump positions live in the shared blob and the
      ## inline fields are unused
    inlineBytes: seq[byte]
    invalidPositions: seq[byte] # bit seq of invalid jump positions
    processed: int ## First position not yet scanned for PUSH data
    persisted*: bool ## This code stream has been persisted to the database

var
  liveCodeBlobs*: Atomic[int]
  liveCodeBlobBytes*: Atomic[int]

template bitpos(pos: int): (int, byte) =
  (pos shr 3, 1'u8 shl (pos and 0x07))

template bitmapLen(len: int): int =
  (len + 7) shr 3

func blobSize(len: int): int =
  sizeof(CodeBlobHeader) + len + bitmapLen(len)

func codeData(b: CodeBlob): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](cast[uint](b) + uint(sizeof(CodeBlobHeader)))

func bitmapData(b: CodeBlob): ptr UncheckedArray[Atomic[uint8]] =
  cast[ptr UncheckedArray[Atomic[uint8]]](
    cast[uint](b) + uint(sizeof(CodeBlobHeader) + b.codeLen))

func len*(b: CodeBlob): int =
  b.codeLen

proc newCodeBlob*(
    bytes: openArray[byte], invalidPositions: openArray[byte] = [], processed = 0
): CodeBlob =
  ## Allocates a blob whose single reference is owned by the caller
  let size = blobSize(bytes.len)
  result = cast[CodeBlob](c_malloc(csize_t(size)))
  result.refCount.store(1, moRelaxed)
  result.processed.store(processed, moRelaxed)
  result.scanLock.store(false, moRelaxed)
  result.codeLen = bytes.len
  if bytes.len > 0:
    copyMem(result.codeData, unsafeAddr bytes[0], bytes.len)
  let bitmap = cast[pointer](result.bitmapData)
  zeroMem(bitmap, bitmapLen(bytes.len))
  if invalidPositions.len > 0:
    copyMem(bitmap, unsafeAddr invalidPositions[0],
      min(invalidPositions.len, bitmapLen(bytes.len)))
  discard liveCodeBlobs.fetchAdd(1, moRelaxed)
  discard liveCodeBlobBytes.fetchAdd(size, moRelaxed)

proc incRef*(b: CodeBlob) =
  discard b.refCount.fetchAdd(1, moRelaxed)

proc release*(b: CodeBlob) =
  if b.refCount.fetchSub(1, moAcquireRelease) == 1:
    discard liveCodeBlobs.fetchSub(1, moRelaxed)
    discard liveCodeBlobBytes.fetchSub(blobSize(b.codeLen), moRelaxed)
    c_free(b)

func init*(
    T: type CodeBytesRef, bytes: sink seq[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef(inlineBytes: move(bytes), persisted: persisted)

func initCopy*(
    T: type CodeBytesRef, bytes: seq[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef(inlineBytes: bytes, persisted: persisted)

func init*(
    T: type CodeBytesRef, bytes: openArray[byte], persisted = false
): CodeBytesRef =
  CodeBytesRef.init(@bytes, persisted = persisted)

func init*(T: type CodeBytesRef, bytes: openArray[char]): CodeBytesRef =
  CodeBytesRef.init(bytes.toOpenArrayByte(0, bytes.high()))

func fromBlob*(T: type CodeBytesRef, blob: CodeBlob, persisted = false): CodeBytesRef =
  ## Wraps a blob reference held by the caller, which must outlive the handle
  CodeBytesRef(blob: blob, persisted: persisted)

func fromHex*(T: type CodeBytesRef, hex: string): Opt[CodeBytesRef] =
  try:
    Opt.some(CodeBytesRef.init(hexToSeqByte(hex)))
  except ValueError:
    Opt.none(CodeBytesRef)

func codeBlob*(c: CodeBytesRef): CodeBlob =
  c.blob

func len*(c: CodeBytesRef): int {.inline.} =
  if c.blob.isNil: c.inlineBytes.len else: c.blob.codeLen

func codeData*(c: CodeBytesRef): ptr UncheckedArray[byte] {.inline.} =
  if c.blob.isNil:
    if c.inlineBytes.len > 0:
      cast[ptr UncheckedArray[byte]](unsafeAddr c.inlineBytes[0])
    else:
      nil
  else:
    c.blob.codeData

template bytes*(c: CodeBytesRef): openArray[byte] =
  block:
    let code = c
    code.codeData.toOpenArray(0, code.len - 1)

func toBytes*(c: CodeBytesRef): seq[byte] =
  @(c.bytes)

func sharesBlob*(a, b: CodeBytesRef): bool =
  not a.blob.isNil and a.blob == b.blob

func scannedUpTo*(c: CodeBytesRef): int =
  ## First position not yet scanned for PUSH data
  if c.blob.isNil: c.processed else: c.blob.processed.load(moAcquire)

proc toBlob*(c: CodeBytesRef): CodeBlob =
  ## A blob reference owned by the caller - inline code is copied into a new
  ## blob while shared code retains the existing one
  if c.blob.isNil:
    newCodeBlob(c.inlineBytes, c.invalidPositions, c.processed)
  else:
    c.blob.incRef()
    c.blob

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

template scanPushData(
    data: ptr UncheckedArray[byte], codeLen, start, position: int, mark: untyped
): int =
  ## Marks the PUSH data between `start` and `position`, returning the first
  ## position left unscanned - always an opcode boundary
  var i = start
  while i <= position:
    let opcode = Op(data[i])
    if opcode >= Op.Push1 and opcode <= Op.Push32:
      let
        leftBound = i + 1
        rightBound = min(leftBound + (opcode.int - 95), codeLen)
      for z in leftBound ..< rightBound:
        mark(z)
      i = rightBound
    else:
      # Nothing to mark for this byte, nor for any byte before the next
      # PUSH, so step over the whole run in one go
      i = skipToNextPush(data.toOpenArray(0, codeLen - 1), i + 1)
  i

func isValidOpcodeInline(c: CodeBytesRef, position: int): bool =
  if c.invalidPositions.len == 0:
    c.invalidPositions.setLen(bitmapLen(c.inlineBytes.len))

  if position < c.processed:
    return not c.invalidPosition(position)

  template mark(z: int) =
    let (bpos, bbit) = bitpos(z)
    c.invalidPositions[bpos] = c.invalidPositions[bpos] or bbit

  let data = cast[ptr UncheckedArray[byte]](unsafeAddr c.inlineBytes[0])
  c.processed = scanPushData(data, c.inlineBytes.len, c.processed, position, mark)

  not c.invalidPosition(position)

func isValidOpcodeShared(b: CodeBlob, position: int): bool =
  let bitmap = b.bitmapData

  template invalid(pos: int): bool =
    let (bpos, bbit) = bitpos(pos)
    (bitmap[bpos].load(moRelaxed) and bbit) > 0

  if position < b.processed.load(moAcquire):
    return not invalid(position)

  while b.scanLock.exchange(true, moAcquire):
    cpuRelax()

  let processed = b.processed.load(moRelaxed)
  if position >= processed:
    template mark(z: int) =
      let (bpos, bbit) = bitpos(z)
      discard bitmap[bpos].fetchOr(bbit, moRelaxed)

    b.processed.store(
      scanPushData(b.codeData, b.codeLen, processed, position, mark), moRelease)

  b.scanLock.store(false, moRelease)

  not invalid(position)

func isValidOpcode*(c: CodeBytesRef, position: int): bool =
  if position >= c.len:
    false
  elif c.blob.isNil:
    c.isValidOpcodeInline(position)
  else:
    c.blob.isValidOpcodeShared(position)

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
