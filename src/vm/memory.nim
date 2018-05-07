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


# TODO: why is the size passed as a UInt256?
proc extend*(memory: var Memory; startPosition: UInt256; size: UInt256) =
  if size == 0:
    return
  var newSize = ceil32(startPosition + size)
  if newSize <= len(memory).u256:
    return
  var sizeToExtend = newSize - len(memory).u256
  memory.bytes = memory.bytes.concat(repeat(0.byte, sizeToExtend.toInt))

proc newMemory*(size: UInt256): Memory =
  result = newMemory()
  result.extend(0.u256, size)

# TODO: why is the size passed as a UInt256?
proc read*(memory: var Memory, startPosition: UInt256, size: UInt256): seq[byte] =
  result = memory.bytes[startPosition.toInt ..< (startPosition + size).toInt]

# TODO: why is the size passed as a UInt256?
proc write*(memory: var Memory, startPosition: UInt256, size: UInt256, value: seq[byte]) =
  if size == 0:
    return
  #echo size
  #echo startPosition
  #validateGte(startPosition, 0)
  #validateGte(size, 0)
  validateLength(value, size.toInt)
  validateLte(startPosition + size, memory.len)
  let index = memory.len
  if memory.len.u256 < startPosition + size:
    memory.bytes = memory.bytes.concat(repeat(0.byte, memory.len - (startPosition + size).toInt)) # TODO: better logarithmic scaling?

  for z, b in value:
    memory.bytes[z + startPosition.toInt] = b

template write*(memory: var Memory, startPosition: UInt256, size: UInt256, value: cstring) =
  memory.write(startPosition, size, value.toBytes)
