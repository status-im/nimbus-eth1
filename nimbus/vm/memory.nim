# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, stint,
  ../constants, ../errors, ../logging, ../validation, ../utils_numeric, ../utils/bytes

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


proc extend*(memory: var Memory; startPosition: Natural; size: Natural) =
  if size == 0:
    return
  var newSize = ceil32(startPosition + size)
  if newSize <= len(memory):
    return
  var sizeToExtend = newSize - len(memory)
  memory.bytes = memory.bytes.concat(repeat(0.byte, sizeToExtend))

proc newMemory*(size: Natural): Memory =
  result = newMemory()
  result.extend(0, size)

proc read*(memory: var Memory, startPosition: Natural, size: Natural): seq[byte] =
  result = memory.bytes[startPosition ..< (startPosition + size)]

proc write*(memory: var Memory, startPosition: Natural, value: openarray[byte]) =
  let size = value.len
  if size == 0:
    return
  #echo size
  #echo startPosition
  #validateGte(startPosition, 0)
  #validateGte(size, 0)
  validateLte(startPosition + size, memory.len)
  let index = memory.len
  if memory.len < startPosition + size:
    memory.bytes = memory.bytes.concat(repeat(0.byte, memory.len - (startPosition + size))) # TODO: better logarithmic scaling?

  for z, b in value:
    memory.bytes[z + startPosition] = b

template write*(memory: var Memory, startPosition: Natural, size: Natural, value: cstring) =
  memory.write(startPosition, value.toBytes)
