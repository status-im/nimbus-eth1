import
  sequtils, bigints,
  ../constants, ../errors, ../logging, ../validation, ../utils_numeric, ../utils/bytes

type
  Memory* = ref object
    logger*: Logger
    bytes*:  seq[byte]

proc newMemory*: Memory =
  new(result)
  result.bytes = @[]
  result.logger = logging.getLogger("evm.vm.memory.Memory")

proc len*(memory: Memory): int =
  result = len(memory.bytes)

proc extend*(memory: var Memory; startPosition: Int256; size: Int256) =
  if size == 0:
    return
  var newSize = ceil32(startPosition + size)
  if newSize <= len(memory).int256:
    return
  var sizeToExtend = newSize - len(memory).int256
  memory.bytes = memory.bytes.concat(repeat(0.byte, sizeToExtend.getInt))

proc newMemory*(size: Int256): Memory =
  result = newMemory()
  result.extend(0.int256, size)

proc read*(memory: var Memory, startPosition: Int256, size: Int256): seq[byte] =
  result = memory.bytes[startPosition.getInt ..< (startPosition + size).getInt]

proc write*(memory: var Memory, startPosition: Int256, size: Int256, value: seq[byte]) =
  echo value

template write*(memory: var Memory, startPosition: Int256, size: Int256, value: cstring) =
  memory.write(startPosition, size, value.toBytes)
