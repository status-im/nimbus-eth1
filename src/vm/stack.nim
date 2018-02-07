import
  strformat, strutils, sequtils, macros,
  value, ../errors, ../validation, ../utils_numeric, ../constants, ../logging

type

  Stack* = ref object of RootObj
    ##     VM Stack
    logger*: Logger
    values*: seq[Value]

template ensureStackLimit: untyped =
  if len(stack.values) > 1023:
    raise newException(FullStack, "Stack limit reached")

proc len*(stack: Stack): int =
  len(stack.values)

proc push*(stack: var Stack; value: Value) =
  ## Push an item onto the stack
  ensureStackLimit()
  if value.kind == VInt:
    validateGte(value.i, 0)
  else:
    validateStackItem(value.b)

  stack.values.add(value)

proc push*(stack: var Stack; value: int) =
  ## Push an integer onto the stack
  ensureStackLimit()
  validateGte(value, 0)
  
  stack.values.add(Value(kind: VInt, i: value.int256))

proc push*(stack: var Stack; value: Int256) =
  ## Push an integer onto the stack
  ensureStackLimit()
  validateGte(value, 0)

  stack.values.add(Value(kind: VInt, i: value))

proc push*(stack: var Stack; value: string) =
  ## Push a binary onto the stack
  ensureStackLimit()
  validateStackItem(value)

  stack.values.add(Value(kind: VBinary, b: value))

proc internalPop(stack: var Stack; numItems: int): seq[Value] =
  if len(stack) < numItems: 
    result = @[]
  else:
    result = stack.values[^numItems .. ^1]
    stack.values = stack.values[0 ..< ^numItems]

template toType(i: Int256, _: typedesc[Int256]): Int256 =
  i

template toType(i: Int256, _: typedesc[string]): string =
  intToBigEndian(i)

template toType(b: string, _: typedesc[Int256]): Int256 =
  bigEndianToInt(b)

template toType(b: string, _: typedesc[string]): string =
  b

proc internalPop(stack: var Stack; numItems: int, T: typedesc): seq[T] =
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

proc pop*(stack: var Stack): Value =
  ## Pop an item off the stack
  var elements = stack.internalPop(1)
  ensurePop(elements, 1)
  result = elements[0]

proc pop*(stack: var Stack; numItems: int): seq[Value] =
  ## Pop many items off the stack
  result = stack.internalPop(numItems)
  ensurePop(result, numItems)

proc popInt*(stack: var Stack): Int256 =
  var elements = stack.internalPop(1, Int256)
  ensurePop(elements, 1)
  result = elements[0]

macro internalPopTuple(numItems: static[int]): untyped =
  var name = ident(&"internalPopTuple{numItems}")
  var typ = nnkPar.newTree()
  var t = ident("T")
  var resultNode = ident("result")
  var stackNode = ident("stack")
  for z in 0 ..< numItems:
    typ.add(t)
  result = quote:
    proc `name`*(`stackNode`: var Stack, `t`: typedesc): `typ`
  result[^1] = nnkStmtList.newTree()
  for z in 0 ..< numItems:
    var zNode = newLit(z)
    var element = quote:
      var value = `stackNode`.values.pop()
      case value.kind:
      of VInt:
        `resultNode`[`zNode`] = toType(value.i, `t`)
      of VBinary:
        `resultNode`[`zNode`] = toType(value.b, `t`)
    result[^1].add(element)

# define pop<T> for tuples
internalPopTuple(2)
internalPopTuple(3)
internalPopTuple(4)
internalPopTuple(5)
internalPopTuple(6)
internalPopTuple(7)

macro popInt*(stack: typed; numItems: static[int]): untyped =
  var resultNode = ident("result")
  if numItems >= 8:
    result = quote:
      `stack`.internalPop(`numItems`, Int256)
  else:
    var name = ident(&"internalPopTuple{numItems}")
    result = quote:
      `name`(`stack`, Int256)
  
# proc popInt*(stack: var Stack, numItems: int): seq[Int256] =
#   result = stack.internalPop(numItems, Int256)
#   ensurePop(result, numItems)

proc popBinary*(stack: var Stack): string =
  var elements = stack.internalPop(1, string)
  ensurePop(elements, 1)
  result = elements[0]

proc popBinary*(stack: var Stack; numItems: int): seq[string] =
  result = stack.internalPop(numItems, string)
  ensurePop(result, numItems)

proc newStack*(): Stack =
  new(result)
  result.logger = logging.getLogger("stack.Stack")
  result.values = @[]

proc swap*(stack: var Stack; position: int) =
  ##  Perform a SWAP operation on the stack
  var idx = position + 1
  if idx < len(stack) + 1:
    (stack.values[^1], stack.values[^idx]) = (stack.values[^idx], stack.values[^1])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for SWAP{position}")

proc dup*(stack: var Stack; position: int | Int256) =
  ## Perform a DUP operation on the stack
  if (position != 0 and position.getInt < stack.len + 1) or (position == 0 and position.getInt < stack.len):
    stack.push(stack.values[^position.getInt])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for DUP{position}")


proc getInt*(stack: Stack, position: int): Int256 =
  let element = stack.values[position]
  case element.kind:
  of VInt:
    result = element.i
  else:
    raise newException(TypeError, "Expected int")

proc getBinary*(stack: Stack, position: int): string =
  let element = stack.values[position]
  case element.kind:
  of VBinary:
    result = element.b
  else:
    raise newException(TypeError, "Expected binary")

proc `$`*(stack: Stack): string =
  let values = stack.values.mapIt(&"  {$it}").join("\n")
  &"Stack:\n{values}"
