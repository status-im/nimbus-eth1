# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  ./validation,
  ./interpreter/utils/utils_numeric

type
  Memory* = ref object
    bytes*:  seq[byte]

logScope:
  topics = "vm memory"

proc newMemory*: Memory =
  new(result)
  result.bytes = @[]

proc len*(memory: Memory): int =
  result = memory.bytes.len

proc extend*(memory: var Memory; startPos: Natural; size: Natural) =
  if size == 0:
    return
  let newSize = ceil32(startPos + size)
  if newSize <= len(memory):
    return
  memory.bytes.setLen(newSize)

proc newMemory*(size: Natural): Memory =
  result = newMemory()
  result.extend(0, size)

proc read*(memory: var Memory, startPos: Natural, size: Natural): seq[byte] =
  result = newSeq[byte](size)
  if size > 0:
    copyMem(result[0].addr, memory.bytes[startPos].addr, size)

when defined(evmc_enabled):
  proc readPtr*(memory: var Memory, startPos: Natural): ptr byte =
    if memory.bytes.len == 0 or startPos >= memory.bytes.len: return
    result = memory.bytes[startPos].addr

proc write*(memory: var Memory, startPos: Natural, value: openArray[byte]) =
  let size = value.len
  if size == 0:
    return
  validateLte(startPos + size, memory.len)
  for z, b in value:
    memory.bytes[z + startPos] = b

proc write*(memory: var Memory, startPos: Natural, value: byte) =
  validateLte(startPos + 1, memory.len)
  memory.bytes[startPos] = value

proc copy*(memory: var Memory, dst, src, len: Natural) =
  if len <= 0: return
  memory.extend(max(dst, src), len)
  if dst == src:
    return
  elif dst < src:
    for i in 0..<len:
      memory.bytes[dst+i] = memory.bytes[src+i]
  else: # src > dst
    for i in countdown(len-1, 0):
      memory.bytes[dst+i] = memory.bytes[src+i]

proc writePadded*(memory: var Memory, data: openArray[byte],
                  memPos, dataPos, len: Natural) =

  memory.extend(memPos, len)
  let
    dataEndPos = dataPos.int64 + len
    dataStart  = min(dataPos, data.len)
    dataEnd    = min(data.len, dataEndPos)
    dataLen    = dataEnd - dataStart
    padStart   = min(memPos + dataLen, memory.len)
    numPad     = min(memory.len - padStart, len - dataLen)
    padEnd     = padStart + numPad

  var
    di = dataStart
    mi = memPos

  while di < dataEnd:
    memory.bytes[mi] = data[di]
    inc di
    inc mi

  # although memory.extend already pad new block of memory
  # with zeros, it can be rewrite by some opcode
  # so we need to clean the garbage if current op supply us with
  # `data` shorter than `len`
  while mi < padEnd:
    memory.bytes[mi] = 0.byte
    inc mi
