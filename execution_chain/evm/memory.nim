# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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

const
  evmMemoryPoolMax = 32
    ## Number of memory buffers kept alive per thread by `dispose` for reuse by a
    ## later `init`.

  evmMemoryRetainMax = 64 * 1024
    ## Buffers grown past this are released rather than pooled, so that a single
    ## memory hungry transaction cannot pin megabytes per thread.

type
  EvmMemory* = object
    bytes*:  seq[byte]

var
  memoryPool {.threadvar.}: array[evmMemoryPoolMax, seq[byte]]
    ## Thread-local for the same reasons as the EVM stack pool, see `stack.nim`.
    ## Buffers are moved in and out with `swap`: under refc, assigning a seq into
    ## a container deep copies it, which costs more than the allocation the pool
    ## is there to avoid.
  memoryPoolLen {.threadvar.}: int
    ## Slots below this hold a buffer, slots at or above it are empty.

func init*(_: type EvmMemory): EvmMemory =
  {.cast(noSideEffect).}:
    if memoryPoolLen > 0:
      dec memoryPoolLen
      swap(result.bytes, memoryPool[memoryPoolLen])
      result.bytes.setLen(0)
    else:
      result.bytes = newSeqOfCap[byte](1024)

func dispose*(memory: var EvmMemory) =
  ## Return the buffer to the pool. `extend` re-zeroes whatever it exposes, both
  ## under refc (`setLengthSeqImpl`) and arc (`setLen`), so a recycled buffer
  ## never leaks the previous frame's bytes.
  {.cast(noSideEffect).}:
    let cap = memory.bytes.capacity
    if cap > 0 and cap <= evmMemoryRetainMax and memoryPoolLen < evmMemoryPoolMax:
      swap(memoryPool[memoryPoolLen], memory.bytes)
      inc memoryPoolLen
    else:
      memory.bytes = @[]

template len*(memory: EvmMemory): int =
  memory.bytes.len

template extend*(memory: var EvmMemory; startPos, size: int) =
  let sz = size
  if sz > 0:
    let newSize = ceil32(startPos + sz)
    if newSize > memory.bytes.len:
      memory.bytes.setLen(newSize)

func init*(_: type EvmMemory, size: Natural): EvmMemory =
  result = EvmMemory.init()
  result.extend(0, size)

template read*(memory: EvmMemory, startPos, size: int): openArray[byte] =
  memory.bytes.toOpenArray(startPos, startPos + size - 1)

template read32Bytes*(memory: EvmMemory, startPos: int): openArray[byte] =
  memory.bytes.toOpenArray(startPos, startPos + 31)

func write*(memory: var EvmMemory, startPos: Natural, value: openArray[byte]): EvmResultVoid {.inline.} =
  let size = value.len
  if size == 0:
    return
  if startPos + size > memory.len:
    return err(memErr(MemoryFull))

  assign(memory.bytes.toOpenArray(startPos, int(startPos + size) - 1), value)
  ok()

func write*(memory: var EvmMemory, startPos: Natural, value: byte): EvmResultVoid {.inline.} =
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
  if mi < padEnd:
    zeroMem(addr memory.bytes[mi], padEnd - mi)
