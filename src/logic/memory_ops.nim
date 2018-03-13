import
  ../constants, ../computation, ../types, .. / vm / [stack, memory], .. / utils / [padding, bytes]


{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc mstoreX(computation; x: int) =
  let start = stack.popInt()
  let value = stack.popBinary()

  let paddedValue = padLeft(value, x, 0.byte)
  let normalizedValue = paddedValue[^x .. ^1]
  
  extendMemory(start, x.u256)
  memory.write(start, 32.u256, normalizedValue)

# TODO template handler

proc mstore*(computation) =
  mstoreX(32)

proc mstore8*(computation) =
  mstoreX(1)

proc mload*(computation) =
  let start = stack.popInt()

  extendMemory(start, 32.u256)

  let value = memory.read(start, 32.u256)
  stack.push(value)

proc msize*(computation) =
  stack.push(memory.len.u256)
