import
  ../constants, ../computation, .. / vm / [stack, memory], .. / utils / [padding, bytes]


{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc mstoreX(computation; x: int) =
  let start = stack.popInt()
  let value = stack.popBinary()

  let paddedValue = padLeft(value, x, cstring"\x00")
  let normalizedValue = cstring(($paddedValue)[^x .. ^1])

  extendMemory(start, x.int256)
  memory.write(start, 32.int256, normalizedValue)

proc mstore*(computation) {.inline.} =
  mstoreX(32)

proc mstore8*(computation) {.inline.} =
  mstoreX(1)

proc mload*(computation) =
  let start = stack.popInt()

  extendMemory(start, 32.int256)

  let value = memory.read(start, 32.int256).toCstring
  stack.push(value)

proc msize*(computation) =
  stack.push(memory.len)
