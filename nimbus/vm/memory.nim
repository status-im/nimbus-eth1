# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils,
  eth_common/eth_types,
  ../constants, ../errors, ../logging, ../validation, ../utils/bytes,
  ./utils/utils_numeric

type
  Memory* = ref object
    logger*: Logger
    bytes*:  seq[byte]

proc newMemory*: Memory =
  new(result)
  result.bytes = @[]
  result.logger = logging.getLogger("memory.Memory")

proc len*(memory: Memory): int =
  result = memory.bytes.len


proc extend*(memory: var Memory; startPos: Natural; size: Natural) =
  if size == 0:
    return
  var newSize = ceil32(startPos + size)
  if newSize <= len(memory):
    return
  var sizeToExtend = newSize - len(memory)
  memory.bytes = memory.bytes.concat(repeat(0.byte, sizeToExtend))

proc newMemory*(size: Natural): Memory =
  result = newMemory()
  result.extend(0, size)

proc read*(memory: var Memory, startPos: Natural, size: Natural): seq[byte] =
  result = memory.bytes[startPos ..< (startPos + size)]

proc write*(memory: var Memory, startPos: Natural, value: openarray[byte]) =
  let size = value.len
  if size == 0:
    return
  #echo size
  #echo startPos
  #validateGte(startPos, 0)
  #validateGte(size, 0)
  validateLte(startPos + size, memory.len)
  let index = memory.len
  if memory.len < startPos + size:
    memory.bytes = memory.bytes.concat(repeat(0.byte, memory.len - (startPos + size))) # TODO: better logarithmic scaling?

  for z, b in value:
    memory.bytes[z + startPos] = b

proc writePaddingBytes*(memory: var Memory,
                        startPos, numberOfBytes: Natural,
                        paddingValue = 0.byte) =
  let endPos = startPos + numberOfBytes
  assert endPos < memory.len
  for i in startPos ..< endPos:
    memory.bytes[i] = paddingValue

template write*(memory: var Memory, startPos: Natural, size: Natural, value: cstring) =
  memory.write(startPos, value.toBytes)
  # TODO ~ O(n^3):
  #  - there is a string allocation with $ (?)
  #  - then a conversion to seq (= new allocation) with toBytes
  #  - then writing to memory
