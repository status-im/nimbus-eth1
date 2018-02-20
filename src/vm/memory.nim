import
  sequtils, ttmath,
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

proc extend*(memory: var Memory; startPosition: UInt256; size: UInt256) =
  if size == 0:
    return
  var newSize = ceil32(startPosition + size)
  if newSize <= len(memory).u256:
    return
  var sizeToExtend = newSize - len(memory).u256
  memory.bytes = memory.bytes.concat(repeat(0.byte, sizeToExtend.getUInt.int))

proc newMemory*(size: UInt256): Memory =
  result = newMemory()
  result.extend(0.u256, size)

proc read*(memory: var Memory, startPosition: UInt256, size: UInt256): seq[byte] =
  result = memory.bytes[startPosition.getUInt.int ..< (startPosition + size).getUInt.int]

proc write*(memory: var Memory, startPosition: UInt256, size: UInt256, value: seq[byte]) =
  if size == 0:
    return
  #echo size 
  #echo startPosition
  #validateGte(startPosition, 0)
  #validateGte(size, 0)
  validateLength(value, size.getUInt.int)
  validateLte(startPosition + size, memory.len)
  let index = memory.len
  if memory.len.u256 < startPosition + size:
    memory.bytes = memory.bytes.concat(repeat(0.byte, memory.len - (startPosition + size).getUInt.int)) # TODO: better logarithmic scaling?

  for z, b in value:
    memory.bytes[z + startPosition.getUInt.int] = b

template write*(memory: var Memory, startPosition: UInt256, size: UInt256, value: cstring) =
  memory.write(startPosition, size, value.toBytes)
