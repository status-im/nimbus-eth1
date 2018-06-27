# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, macros, rlp, eth_common, nimcrypto,
  ../errors, ../validation, ./utils/utils_numeric, ../constants, ../logging, .. / utils / bytes

type
  Stack* = ref object of RootObj
    logger*: Logger
    values*: seq[StackElement]

  StackElement = UInt256

template ensureStackLimit: untyped =
  if len(stack.values) > 1023:
    raise newException(FullStack, "Stack limit reached")

proc len*(stack: Stack): int {.inline.} =
  len(stack.values)

proc toStackElement(v: UInt256, elem: var StackElement) {.inline.} = elem = v
proc toStackElement(v: uint | int, elem: var StackElement) {.inline.} = elem = v.u256
proc toStackElement(v: EthAddress, elem: var StackElement) {.inline.} = elem = bigEndianToInt(v)
proc toStackElement(v: MDigest, elem: var StackElement) {.inline.} = elem = readUintBE[256](v.data)

proc fromStackElement(elem: StackElement, v: var UInt256) {.inline.} = v = elem
proc fromStackElement(elem: StackElement, v: var EthAddress) {.inline.} = v[0 .. ^1] = elem.toByteArrayBE().toOpenArray(0, 19)
proc fromStackElement(elem: StackElement, v: var Hash256) {.inline.} = v.data = elem.toByteArrayBE()

proc toStackElement(v: seq[byte], elem: var StackElement) {.inline.} =
  # TODO: This needs to go
  validateStackItem(v)
  elem = bigEndianToInt(v)

proc pushAux[T](stack: var Stack, value: T) =
  ensureStackLimit()
  stack.values.setLen(stack.values.len + 1)
  toStackElement(value, stack.values[^1])

proc push*(stack: var Stack, value: uint | UInt256 | EthAddress | Hash256) {.inline.} =
  pushAux(stack, value)

proc push*(stack: var Stack, value: seq[byte]) {.inline.} =
  # TODO: This needs to go...
  pushAux(stack, value)

proc ensurePop(elements: Stack, a: int) =
  let num = elements.len
  let expected = a
  if num < expected:
    raise newException(InsufficientStack,
      &"Stack underflow: expected {expected} elements, got {num} instead.")

proc popAux[T](stack: var Stack, value: var T) =
  ensurePop(stack, 1)
  fromStackElement(stack.values[^1], value)
  stack.values.setLen(stack.values.len - 1)

proc internalPopTuple(stack: var Stack, v: var tuple, tupleLen: static[int]) =
  ensurePop(stack, tupleLen)
  var i = 0
  let sz = stack.values.high
  for f in fields(v):
    fromStackElement(stack.values[sz - i], f)
    inc i
  stack.values.setLen(sz - tupleLen + 1)

proc popInt*(stack: var Stack): UInt256 {.inline.} =
  popAux(stack, result)

macro genTupleType(len: static[int], elemType: untyped): untyped =
  result = nnkTupleConstr.newNimNode()
  for i in 0 ..< len: result.add(elemType)

proc popInt*(stack: var Stack, numItems: static[int]): auto {.inline.} =
  var r: genTupleType(numItems, UInt256)
  stack.internalPopTuple(r, numItems)
  return r

proc popAddress*(stack: var Stack): EthAddress {.inline.} =
  popAux(stack, result)

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

template getint(x: int): int = x

proc dup*(stack: var Stack, position: int | UInt256) =
  ## Perform a DUP operation on the stack
  let position = position.getInt
  if position in 1 .. stack.len:
    stack.push(stack.values[^position])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for DUP{position}")

proc peek*(stack: Stack): UInt256 =
  # This should be used only for testing purposes!
  fromStackElement(stack.values[^1], result)

proc `$`*(stack: Stack): string =
  let values = stack.values.mapIt(&"  {$it}").join("\n")
  &"Stack:\n{values}"
