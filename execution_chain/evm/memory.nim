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
  stew/assign2,
  ./evm_errors,
  ./interpreter/utils/utils_numeric

type
  EvmMemory* = object
    bytes*:  seq[byte]

func init*(_: type EvmMemory): EvmMemory =
  EvmMemory(
    bytes: newSeqOfCap[byte](1024)
  )

func len*(memory: EvmMemory): int =
  memory.bytes.len

func extend*(memory: var EvmMemory; startPos, size: int) =
  if size <= 0:
    return
  let newSize = ceil32(startPos + size)
  if newSize <= len(memory):
    return
  memory.bytes.setLen(newSize)

func init*(_: type EvmMemory, size: Natural): EvmMemory =
  result = EvmMemory.init()
  result.extend(0, size)

template read*(memory: EvmMemory, startPos, size: int): openArray[byte] =
  memory.bytes.toOpenArray(startPos, startPos + size - 1)

template read32Bytes*(memory: EvmMemory, startPos: int): openArray[byte] =
  memory.bytes.toOpenArray(startPos, startPos + 31)

when defined(evmc_enabled):
  func readPtr*(memory: EvmMemory, startPos: Natural): ptr byte =
    if memory.bytes.len == 0 or startPos >= memory.bytes.len: return
    result = memory.bytes[startPos].addr

func write*(memory: var EvmMemory, startPos: Natural, value: openArray[byte]): EvmResultVoid =
  let size = value.len
  if size == 0:
    return
  if startPos + size > memory.len:
    return err(memErr(MemoryFull))

  assign(memory.bytes.toOpenArray(startPos, int(startPos + size) - 1), value)
  ok()

func write*(memory: var EvmMemory, startPos: Natural, value: byte): EvmResultVoid =
  if startPos + 1 > memory.len:
    return err(memErr(MemoryFull))
  memory.bytes[startPos] = value
  ok()

func copy*(memory: var EvmMemory, dst, src, len: Natural) =
  if len <= 0: return
  memory.extend(max(dst, src), len)
  if dst == src:
    return
  assign(
    memory.bytes.toOpenArray(dst, dst + len - 1),
    memory.bytes.toOpenArray(src, src + len - 1))

func writePadded*(memory: var EvmMemory, data: openArray[byte],
                  memPos, dataPos, len: Natural) =

  memory.extend(memPos, len)
  let
    dataEndPos = dataPos + len
    dataStart  = min(dataPos, data.len)
    dataEnd    = min(data.len, dataEndPos)
    dataLen    = dataEnd - dataStart
    padStart   = min(memPos + dataLen, memory.len)
    numPad     = min(memory.len - padStart, len - dataLen)
    padEnd     = padStart + numPad

  var
    di = dataStart
    mi = memPos

  assign(
    memory.bytes.toOpenArray(mi, mi + dataLen - 1),
    data.toOpenArray(di, di + dataLen - 1))
  mi += dataLen

  # although memory.extend already pad new block of memory
  # with zeros, it can be rewrite by some opcode
  # so we need to clean the garbage if current op supply us with
  # `data` shorter than `len`
  while mi < padEnd:
    memory.bytes[mi] = 0.byte
    inc mi
