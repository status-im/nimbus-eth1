# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ./evm_errors,
  ./interpreter/utils/utils_numeric

type
  EvmMemoryRef* = ref object
    bytes*:  seq[byte]

func new*(_: type EvmMemoryRef): EvmMemoryRef =
  new(result)
  result.bytes = @[]

func len*(memory: EvmMemoryRef): int =
  result = memory.bytes.len

func extend*(memory: EvmMemoryRef; startPos: Natural; size: Natural) =
  if size == 0:
    return
  let newSize = ceil32(startPos + size)
  if newSize <= len(memory):
    return
  memory.bytes.setLen(newSize)

func new*(_: type EvmMemoryRef, size: Natural): EvmMemoryRef =
  result = EvmMemoryRef.new()
  result.extend(0, size)

func read*(memory: EvmMemoryRef, startPos: Natural, size: Natural): seq[byte] =
  result = newSeq[byte](size)
  if size > 0:
    copyMem(result[0].addr, memory.bytes[startPos].addr, size)

template read32Bytes*(memory: EvmMemoryRef, startPos): auto =
  memory.bytes.toOpenArray(startPos, startPos + 31)

when defined(evmc_enabled):
  func readPtr*(memory: EvmMemoryRef, startPos: Natural): ptr byte =
    if memory.bytes.len == 0 or startPos >= memory.bytes.len: return
    result = memory.bytes[startPos].addr

func write*(memory: EvmMemoryRef, startPos: Natural, value: openArray[byte]): EvmResultVoid =
  let size = value.len
  if size == 0:
    return
  if startPos + size > memory.len:
    return err(memErr(MemoryFull))
  for z, b in value:
    memory.bytes[z + startPos] = b
  ok()

func write*(memory: EvmMemoryRef, startPos: Natural, value: byte): EvmResultVoid =
  if startPos + 1 > memory.len:
    return err(memErr(MemoryFull))
  memory.bytes[startPos] = value
  ok()

func copy*(memory: EvmMemoryRef, dst, src, len: Natural) =
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

func writePadded*(memory: EvmMemoryRef, data: openArray[byte],
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
