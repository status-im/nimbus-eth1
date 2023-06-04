# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, eth/common/eth_types,
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
  # TODO: use an openArray[byte]
  result = memory.bytes[startPos ..< (startPos + size)]

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
