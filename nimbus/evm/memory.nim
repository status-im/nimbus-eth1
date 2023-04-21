# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils,
  std/typetraits,
  chronicles, eth/common/eth_types,
  ../utils/functors/[identity, futures, possible_futures],
  ../errors, ./validation,
  ./interpreter/utils/utils_numeric,
  ./async/speculex

logScope:
  topics = "vm memory"

# FIXME-Adam: this is obviously horribly inefficient; I can try doing
# something more clever (some sort of binary search tree?) later.

type
  ByteCell* = SpeculativeExecutionCell[byte]
  BytesCell* = SpeculativeExecutionCell[seq[byte]]

proc readCells*(byteCells: var seq[ByteCell], startPos: Natural, size: Natural): seq[ByteCell] =
  byteCells[startPos ..< (startPos + size)]

proc writeCells*(byteCells: var seq[ByteCell], startPos: Natural, newCells: openArray[ByteCell]) =
  let size = newCells.len
  if size == 0:
    return
  validateLte(startPos + size, byteCells.len)
  if byteCells.len < startPos + size:
    byteCells = byteCells.concat(repeat(pureCell(0.byte), byteCells.len - (startPos + size))) # TODO: better logarithmic scaling?

  for z, c in newCells:
    byteCells[z + startPos] = c


type
  Memory* = ref object
    byteCells*:  seq[ByteCell]

proc newMemory*: Memory =
  new(result)
  result.byteCells = @[]

proc len*(memory: Memory): int =
  result = memory.byteCells.len

proc readBytes*(memory: Memory, startPos: Natural, size: Natural): BytesCell {.raises: [CatchableError].} =
  traverse(readCells(memory.byteCells, startPos, size))

proc writeBytes*(memory: Memory, startPos: Natural, size: Natural, newBytesF: BytesCell) =
  var newCells: seq[ByteCell]
  for i in 0..(size-1):
    newCells.add(newBytesF.map(proc(newBytes: seq[byte]): byte = newBytes[i]))
  writeCells(memory.byteCells, startPos, newCells)

proc readAllBytes*(memory: Memory): BytesCell =
  readBytes(memory, 0, len(memory))

proc futureBytes*(memory: Memory, startPos: Natural, size: Natural): Future[seq[byte]] =
  toFuture(readBytes(memory, startPos, size))

proc readConcreteBytes*(memory: Memory, startPos: Natural, size: Natural): seq[byte] =
  waitForValueOf(readBytes(memory, startPos, size))

proc writeConcreteBytes*(memory: Memory, startPos: Natural, value: openArray[byte]) =
  writeBytes(memory, startPos, value.len, pureCell(@value))

when shouldUseSpeculativeExecution:
  proc writeFutureBytes*(memory: Memory, startPos: Natural, size: Natural, newBytesFut: Future[seq[byte]]) =
    writeBytes(memory, startPos, size, newBytesFut)

# FIXME-removeSynchronousInterface: the callers should be fixed so that they don't need this
proc waitForBytes*(memory: Memory): seq[byte] =
  waitForValueOf(readAllBytes(memory))

# FIXME-removeSynchronousInterface: the tests call it "bytes", I dunno how many call sites there are
proc bytes*(memory: Memory): seq[byte] =
  waitForBytes(memory)

proc extend*(memory: var Memory; startPos: Natural; size: Natural) =
  if size == 0:
    return
  var newSize = ceil32(startPos + size)
  if newSize <= len(memory):
    return
  var sizeToExtend = newSize - len(memory)
  memory.byteCells = memory.byteCells.concat(repeat(pureCell(0.byte), sizeToExtend))

proc newMemory*(size: Natural): Memory =
  result = newMemory()
  result.extend(0, size)

when defined(evmc_enabled):
  proc readPtr*(memory: var Memory, startPos: Natural): ptr byte =
    if memory.len == 0 or startPos >= memory.len: return
    result = distinctBase(memory.byteCells[startPos]).addr
