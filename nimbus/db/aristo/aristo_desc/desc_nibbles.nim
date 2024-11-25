# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import stew/[arraybuf, arrayops]

export arraybuf

type
  NibblesBuf* = object
    ## Allocation-free type for storing up to 64 4-bit nibbles, as seen in the
    ## Ethereum MPT
    bytes: array[32, byte]
    ibegin, iend: int8
      # Where valid nibbles can be found - we use indices here to avoid copies
      # wen slicing - iend not inclusive

  HexPrefixBuf* = ArrayBuf[33, byte]

func high*(T: type NibblesBuf): int =
  63

func fromBytes*(T: type NibblesBuf, bytes: openArray[byte]): T =
  result.iend = 2 * (int8 result.bytes.copyFrom(bytes))

func nibble*(T: type NibblesBuf, nibble: byte): T =
  result.bytes[0] = nibble shl 4
  result.iend = 1

template `[]`*(r: NibblesBuf, i: int): byte =
  let pos = r.ibegin + i
  if (pos and 1) != 0:
    (r.bytes[pos shr 1] and 0xf)
  else:
    (r.bytes[pos shr 1] shr 4)

template `[]=`*(r: NibblesBuf, i: int, v: byte) =
  let pos = r.ibegin + i
  r.bytes[pos shr 1] =
    if (pos and 1) != 0:
      (v and 0x0f) or (r.bytes[pos shr 1] and 0xf0)
    else:
      (v shl 4) or (r.bytes[pos shr 1] and 0x0f)

func len*(r: NibblesBuf): int =
  r.iend - r.ibegin

func `==`*(lhs, rhs: NibblesBuf): bool =
  if lhs.len == rhs.len:
    for i in 0 ..< lhs.len:
      if lhs[i] != rhs[i]:
        return false
    return true
  else:
    return false

func `$`*(r: NibblesBuf): string =
  result = newStringOfCap(64)
  for i in 0 ..< r.len:
    const chars = "0123456789abcdef"
    result.add chars[r[i]]

func slice*(r: NibblesBuf, ibegin: int, iend = -1): NibblesBuf {.noinit.} =
  result.bytes = r.bytes
  result.ibegin = r.ibegin + ibegin.int8
  let e =
    if iend < 0:
      min(64, r.iend + iend + 1)
    else:
      min(64, r.ibegin + iend)
  doAssert ibegin >= 0 and e <= result.bytes.len * 2
  result.iend = e.int8

func replaceSuffix*(r: NibblesBuf, suffix: NibblesBuf): NibblesBuf =
  for i in 0 ..< r.len - suffix.len:
    result[i] = r[i]
  for i in 0 ..< suffix.len:
    result[i + r.len - suffix.len] = suffix[i]
  result.iend = min(64, r.len + suffix.len).int8

template writeFirstByte(nibbleCountExpr) {.dirty.} =
  let nibbleCount = nibbleCountExpr
  var oddnessFlag = (nibbleCount and 1) != 0
  result.setLen((nibbleCount div 2) + 1)
  result[0] = byte((int(isLeaf) * 2 + int(oddnessFlag)) shl 4)
  var writeHead = 0

template writeNibbles(r) {.dirty.} =
  for i in 0 ..< r.len:
    let nextNibble = r[i]
    if oddnessFlag:
      result[writeHead] = result[writeHead] or nextNibble
    else:
      inc writeHead
      result[writeHead] = nextNibble shl 4
    oddnessFlag = not oddnessFlag

func toHexPrefix*(r: NibblesBuf, isLeaf = false): HexPrefixBuf =
  writeFirstByte(r.len)
  writeNibbles(r)

func toHexPrefix*(r1, r2: NibblesBuf, isLeaf = false): HexPrefixBuf =
  writeFirstByte(r1.len + r2.len)
  writeNibbles(r1)
  writeNibbles(r2)

func sharedPrefixLen*(lhs, rhs: NibblesBuf): int =
  result = 0
  while result < lhs.len and result < rhs.len:
    if lhs[result] != rhs[result]:
      break
    inc result

func startsWith*(lhs, rhs: NibblesBuf): bool =
  sharedPrefixLen(lhs, rhs) == rhs.len

func fromHexPrefix*(
    T: type NibblesBuf, r: openArray[byte]
): tuple[isLeaf: bool, nibbles: NibblesBuf] {.noinit.} =
  result.nibbles.ibegin = 0

  if r.len > 0:
    result.isLeaf = (r[0] and 0x20) != 0
    let hasOddLen = (r[0] and 0x10) != 0

    result.nibbles.iend =
      if hasOddLen:
        result.nibbles.bytes[0] = r[0] shl 4

        let bytes = min(31, r.len - 1)
        for j in 0 ..< bytes:
          result.nibbles.bytes[j] = result.nibbles.bytes[j] or r[j + 1] shr 4
          result.nibbles.bytes[j + 1] = r[j + 1] shl 4

        int8(bytes) * 2 + 1
      else:
        let bytes = min(32, r.len - 1)
        assign(result.nibbles.bytes.toOpenArray(0, bytes - 1), r.toOpenArray(1, bytes))
        int8(bytes) * 2
  else:
    result.isLeaf = false
    result.nibbles.iend = 0

func `&`*(a, b: NibblesBuf): NibblesBuf {.noinit.} =
  result.ibegin = 0
  for i in 0 ..< a.len:
    result[i] = a[i]

  for i in 0 ..< b.len:
    result[i + a.len] = b[i]

  result.iend = int8(min(64, a.len + b.len))

template getBytes*(a: NibblesBuf): array[32, byte] =
  a.bytes
