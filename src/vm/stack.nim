import
  strformat, strutils, sequtils, macros,
  value, ../errors, ../validation, ../utils_numeric, ../constants, ttmath, ../logging, .. / utils / bytes

type

  Stack* = ref object of RootObj
    logger*: Logger
    values*: seq[UInt256]

template ensureStackLimit: untyped =
  if len(stack.values) > 1023:
    raise newException(FullStack, "Stack limit reached")

proc len*(stack: Stack): int =
  len(stack.values)

template toType(i: UInt256, _: typedesc[UInt256]): UInt256 =
  i

template toType(i: UInt256, _: typedesc[string]): string =
  i.intToBigEndian.toString

template toType(i: UInt256, _: typedesc[Bytes]): Bytes =
  i.intToBigEndian

template toType(b: string, _: typedesc[UInt256]): UInt256 =
  b.toBytes.bigEndianToInt

template toType(b: string, _: typedesc[string]): string =
  b

template toType(b: string, _: typedesc[Bytes]): Bytes =
  b.toBytes

template toType(b: Bytes, _: typedesc[UInt256]): UInt256 =
  b.bigEndianToInt

template toType(b: Bytes, _: typedesc[string]): string =
  b.toString

template toType(b: Bytes, _: typedesc[Bytes]): Bytes =
  b

proc push*(stack: var Stack, value: uint) =
  ## Push an integer onto the stack
  ensureStackLimit()

  stack.values.add(value.u256)

proc push*(stack: var Stack, value: UInt256) =
  ## Push an integer onto the stack
  ensureStackLimit()

  stack.values.add(value)

proc push*(stack: var Stack, value: string) =
  ## Push a binary onto the stack
  ensureStackLimit()
  validateStackItem(value)

  stack.values.add(value.toType(UInt256))

proc push*(stack: var Stack, value: Bytes) =
  ensureStackLimit()
  validateStackItem(value)

  stack.values.add(value.toType(UInt256))

proc internalPop(stack: var Stack, numItems: int): seq[UInt256] =
  if len(stack) < numItems: 
    result = @[]
  else:
    result = stack.values[^numItems .. ^1]
    stack.values = stack.values[0 ..< ^numItems]

proc internalPop(stack: var Stack, numItems: int, T: typedesc): seq[T] =
  result = @[]
  if len(stack) < numItems: 
    return
  
  for z in 0 ..< numItems:
    var value = stack.values.pop()
    result.add(toType(value, T))

template ensurePop(elements: untyped, a: untyped): untyped =
  if len(`elements`) < `a`:
    raise newException(InsufficientStack, "No stack items")

proc popInt*(stack: var Stack): UInt256 =
  var elements = stack.internalPop(1, UInt256)
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
      `resultNode`[`zNode`] = toType(value, `t`)
    result[^1].add(element)

# define pop<T> for tuples
internalPopTuple(2)
internalPopTuple(3)
internalPopTuple(4)
internalPopTuple(5)
internalPopTuple(6)
internalPopTuple(7)

macro popInt*(stack: typed, numItems: static[int]): untyped =
  var resultNode = ident("result")
  if numItems >= 8:
    result = quote:
      `stack`.internalPop(`numItems`, UInt256)
  else:
    var name = ident(&"internalPopTuple{numItems}")
    result = quote:
      `name`(`stack`, UInt256)
  
proc popBinary*(stack: var Stack): Bytes =
  var elements = stack.internalPop(1, Bytes)
  ensurePop(elements, 1)
  result = elements[0]

proc popBinary*(stack: var Stack, numItems: int): seq[Bytes] =
  result = stack.internalPop(numItems, Bytes)
  ensurePop(result, numItems)

proc popString*(stack: var Stack): string =
  var elements = stack.internalPop(1, string)
  ensurePop(elements, 1)
  result = elements[0]

proc popString*(stack: var Stack, numItems: int): seq[string] =
  result = stack.internalPop(numItems, string)
  ensurePop(result, numItems)

proc newStack*(): Stack =
  new(result)
  result.logger = logging.getLogger("stack.Stack")
  result.values = @[]

proc swap*(stack: var Stack, position: int) =
  ##  Perform a SWAP operation on the stack
  var idx = position + 1
  if idx < len(stack) + 1:
    (stack.values[^1], stack.values[^idx]) = (stack.values[^idx], stack.values[^1])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for SWAP{position}")

proc dup*(stack: var Stack, position: int | UInt256) =
  ## Perform a DUP operation on the stack
  if (position != 0 and position.getInt < stack.len + 1) or (position == 0 and position.getInt < stack.len):
    stack.push(stack.values[^position.getInt])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for DUP{position}")


proc getInt*(stack: Stack, position: int): UInt256 =
  stack.values[position]

proc getBinary*(stack: Stack, position: int): Bytes =
  stack.values[position].toType(Bytes)

proc getString*(stack: Stack, position: int): string =
  stack.values[position].toType(string)

proc `$`*(stack: Stack): string =
  let values = stack.values.mapIt(&"  {$it}").join("\n")
  &"Stack:\n{values}"
