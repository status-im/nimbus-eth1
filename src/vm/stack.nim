
import
  strformat,
  value, ../errors, ../validation, ../utils_numeric, ../constants, ../logging

type

  Stack* = ref object of RootObj
    ##     VM Stack
    logger*: Logger
    values*: seq[Value]

template ensureStackLimit: untyped =
  if len(stack.values) > 1023:
    raise newException(FullStack, "Stack limit reached")

method len*(stack: Stack): int =
  len(stack.values)

method push*(stack: var Stack; value: Value) =
  ## Push an item onto the stack
  ensureStackLimit()

  stack.values.add(value)

method push*(stack: var Stack; value: int) =
  ## Push an integer onto the stack
  ensureStackLimit()

  stack.values.add(Value(kind: VInt, i: value))

method push*(stack: var Stack; value: cstring) =
  ## Push a binary onto the stack
  ensureStackLimit()

  stack.values.add(Value(kind: VBinary, b: value))

method internalPop(stack: var Stack; numItems: int): seq[Value] =
  if len(stack) < numItems: 
    result = @[]
  else:
    result = stack.values[^numItems .. ^1]
    stack.values = stack.values[0 ..< ^numItems]

template toType(i: int, _: typedesc[int]): int =
  i

template toType(i: int, _: typedesc[cstring]): cstring =
  intToBigEndian(i)

template toType(b: cstring, _: typedesc[int]): int =
  bigEndianToInt(b)

template toType(b: cstring, _: typedesc[cstring]): cstring =
  b

method internalPop(stack: var Stack; numItems: int, T: typedesc): seq[T] =
  result = @[]
  if len(stack) < numItems: 
    return
  
  for z in 0 ..< numItems:
    var value = stack.values.pop()
    case value.kind:
    of VInt:
      result.add(toType(value.i, T))
    of VBinary:
      result.add(toType(value.b, T))

template ensurePop(elements: untyped, a: untyped): untyped =
  if len(`elements`) < `a`:
    raise newException(InsufficientStack, "No stack items")

method pop*(stack: var Stack): Value =
  ## Pop an item off the stack
  var elements = stack.internalPop(1)
  ensurePop(elements, 1)
  result = elements[0]

method pop*(stack: var Stack; numItems: int): seq[Value] =
  ## Pop many items off the stack
  result = stack.internalPop(numItems)
  ensurePop(result, numItems)

method popInt*(stack: var Stack): int =
  var elements = stack.internalPop(1, int)
  ensurePop(elements, 1)
  result = elements[0]

method popInt*(stack: var Stack; numItems: int): seq[int] =
  result = stack.internalPop(numItems, int)
  ensurePop(result, numItems)

method popBinary*(stack: var Stack): cstring =
  var elements = stack.internalPop(1, cstring)
  ensurePop(elements, 1)
  result = elements[0]

method popBinary*(stack: var Stack; numItems: int): seq[cstring] =
  result = stack.internalPop(numItems, cstring)
  ensurePop(result, numItems)

proc makeStack*(): Stack =
  # result.logger = logging.getLogger("evm.vm.stack.Stack")
  result.values = @[]

method swap*(stack: var Stack; position: int) =
  ##  Perform a SWAP operation on the stack
  var idx = position + 1
  if idx < len(stack) + 1:
    (stack.values[^1], stack.values[^idx]) = (stack.values[^idx], stack.values[^1])
  else:
    raise newException(InsufficientStack,
                      %"Insufficient stack items for SWAP{position}")

method dup*(stack: var Stack; position: int) =
  ## Perform a DUP operation on the stack
  if position < len(stack) + 1:
    stack.push(stack.values[^position])
  else:
    raise newException(InsufficientStack,
                      %"Insufficient stack items for DUP{position}")

