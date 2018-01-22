import
  ../constants, ../computation, .. / vm / [stack, memory], ../utils/padding


proc mstoreX(computation: var BaseComputation, x: int) =
  let start = computation.stack.popInt()
  let value = computation.stack.popBinary()

  let paddedValue = pad_left(value, x, cstring"\x00")
  let normalizedValue = cstring(($paddedValue)[^x .. ^1])

  computation.extendMemory(start, x.int256)
  computation.memory.write(start, 32.int256, normalizedValue)

template mstore*(computation: var BaseComputation) =
  mstoreX(32)

template mstore8*(computation: var BaseComputation) =
  mstoreX(1)

proc mload*(computation: var BaseComputation) =
  let start = computation.stack.popInt()

  computation.extendMemory(start, 32.int256)

  let value = computation.memory.read(start, 32.int256)
  computation.stack.push(value)

proc msize*(computation: var BaseComputation) =
  computation.stack.push(computation.memory.len)
