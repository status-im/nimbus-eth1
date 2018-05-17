# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, macros, rlp,
  value, ../errors, ../validation, ../utils_numeric, ../constants, stint, ../logging, .. / utils / bytes

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
  # TODO: it is very inefficient to allocate a seq
  assert  numItems <= stack.len
  result = stack.values[^numItems .. ^1]
  stack.values = stack.values[0 ..< ^numItems]

proc internalPop(stack: var Stack, numItems: int, T: typedesc): seq[T] =
  # TODO: it is very inefficient to allocate a seq

  assert  numItems <= stack.len
  result = @[]

  for z in 0 ..< numItems:
    var value = stack.values.pop()
    result.add(toType(value, T))

proc ensurePop(elements: seq|Stack, a: int) =
  let num = elements.len
  let expected = a
  if num < expected:
    raise newException(InsufficientStack,
      &"Stack underflow: expected {expected} elements, got {num} instead.")

proc popInt*(stack: var Stack): UInt256 =
  ensurePop(stack, 1)
  var elements = stack.internalPop(1, UInt256)
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
  result[^1].add quote do:
    ensurePop(`stackNode`, `numItems`)
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
  if stack.values.len <= position:
    raise newException(InsufficientStack, &"No {position} item")
  else:
    stack.values[position]

proc getBinary*(stack: Stack, position: int): Bytes =
  stack.values[position].toType(Bytes)

proc getString*(stack: Stack, position: int): string =
  stack.values[position].toType(string)

proc peek*(stack: Stack): UInt256 =
  stack.getInt(stack.values.len - 1)

proc `$`*(stack: Stack): string =
  let values = stack.values.mapIt(&"  {$it}").join("\n")
  &"Stack:\n{values}"
