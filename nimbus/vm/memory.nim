# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils,
  chronicles, eth/common/eth_types,
  ../errors, ../validation,
  ./interpreter/utils/utils_numeric

logScope:
  topics = "vm memory"

type
  Memory* = ref object
    bytes*:  seq[byte]

proc newMemory*: Memory =
  new(result)
  result.bytes = @[]

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
  # TODO: use an openarray[byte]
  result = memory.bytes[startPos ..< (startPos + size)]

when defined(evmc_enabled):
  proc readPtr*(memory: var Memory, startPos: Natural): ptr byte =
    if memory.bytes.len == 0 or startPos > memory.bytes.len: return
    result = memory.bytes[startPos].addr

proc write*(memory: var Memory, startPos: Natural, value: openarray[byte]) =
  let size = value.len
  if size == 0:
    return
  #echo size
  #echo startPos
  validateLte(startPos + size, memory.len)
  if memory.len < startPos + size:
    memory.bytes = memory.bytes.concat(repeat(0.byte, memory.len - (startPos + size))) # TODO: better logarithmic scaling?

  for z, b in value:
    memory.bytes[z + startPos] = b
