# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strformat, strutils, sequtils, macros],
  chronicles, chronos, eth/common,
  ../utils/functors/[identity, futures, possible_futures],
  ../errors, ./validation,
  ./async/speculex

logScope:
  topics = "vm stack"

# Now that we need a stack that contains values that may not be available yet,
# the terminology below makes a clearer distinction between:
#   "stack value" (the actual UInt256)
#   "stack element" (the possibly-not-resolved-yet box that will eventually hold the value).

type StackElement = SpeculativeExecutionCell[UInt256]
proc pureStackElement*(v: UInt256): StackElement {.inline.} = pureCell(v)

type
  Stack* = ref object of RootObj
    elements*: seq[StackElement]

proc values*(stack: Stack): seq[UInt256] =
  stack.elements.map(proc(elem: StackElement): UInt256 =
                       unsafeGetAlreadyAvailableValue(elem))

proc len*(stack: Stack): int {.inline.} =
  len(stack.elements)

template ensureStackLimit: untyped =
  if len(stack.elements) > 1023:
    raise newException(FullStack, "Stack limit reached")


proc stackValueFrom*(v: UInt256): UInt256 {.inline.} = v
proc stackValueFrom*(v: uint | int | GasInt): UInt256 {.inline.} = v.u256
proc stackValueFrom*(v: EthAddress): UInt256 {.inline.} = result.initFromBytesBE(v)
proc stackValueFrom*(v: MDigest): UInt256 {.inline.} = result.initFromBytesBE(v.data, allowPadding = false)

proc stackValueFrom*(v: openArray[byte]): UInt256 {.inline.} =
  # TODO: This needs to go
  validateStackItem(v) # This is necessary to pass stack tests
  result.initFromBytesBE(v)

proc fromStackValue(i: UInt256, v: var UInt256) {.inline.} = v = i
proc fromStackValue(i: UInt256, v: var EthAddress) {.inline.} = v[0 .. ^1] = i.toByteArrayBE().toOpenArray(12, 31)
proc fromStackValue(i: UInt256, v: var Hash256) {.inline.} = v.data = i.toByteArrayBE()
proc fromStackValue(i: UInt256, v: var Topic) {.inline.} = v = i.toByteArrayBE()

proc     intFromStackValue*(i: UInt256): UInt256    {.inline.} = i
proc addressFromStackValue*(i: UInt256): EthAddress {.inline.} = fromStackValue(i, result)
proc    hashFromStackValue*(i: UInt256): Hash256    {.inline.} = fromStackValue(i, result)
proc   topicFromStackValue*(i: UInt256): Topic      {.inline.} = fromStackValue(i, result)

proc futureStackValue*(elem: StackElement): Future[UInt256] =
  toFuture(elem)

proc futureInt*    (elem: StackElement): Future[UInt256]    {.async.} = return     intFromStackValue(await futureStackValue(elem))
proc futureAddress*(elem: StackElement): Future[EthAddress] {.async.} = return addressFromStackValue(await futureStackValue(elem))
proc futureHash*   (elem: StackElement): Future[Hash256]    {.async.} = return    hashFromStackValue(await futureStackValue(elem))
proc futureTopic*  (elem: StackElement): Future[Topic]      {.async.} = return   topicFromStackValue(await futureStackValue(elem))



# FIXME-Adam: we may not need anything other than the StackElement one, after we're done refactoring
proc pushAux[T](stack: var Stack, value: T) =
  ensureStackLimit()
  stack.elements.setLen(stack.elements.len + 1)
  stack.elements[^1] = pureStackElement(stackValueFrom(value))

proc push*(stack: var Stack, value: uint | int | GasInt | UInt256 | EthAddress | Hash256) {.inline.} =
  pushAux(stack, value)

proc push*(stack: var Stack, value: openArray[byte]) {.inline.} =
  # TODO: This needs to go...
  pushAux(stack, value)

proc pushElement*(stack: var Stack, elem: StackElement) =
  ensureStackLimit()
  stack.elements.setLen(stack.elements.len + 1)
  stack.elements[^1] = elem

proc push*(stack: var Stack, elem: StackElement) =
  stack.pushElement(elem)

proc ensurePop(stack: Stack, expected: int) =
  let num = stack.len
  if num < expected:
    raise newException(InsufficientStack,
      &"Stack underflow: expected {expected} elements, got {num} instead.")

proc internalPopElementsTuple(stack: var Stack, v: var tuple, tupleLen: static[int]) =
  ensurePop(stack, tupleLen)
  var i = 0
  let sz = stack.elements.high
  for f in fields(v):
    f = stack.elements[sz - i]
    inc i
  stack.elements.setLen(sz - tupleLen + 1)

macro genTupleType*(len: static[int], elemType: untyped): untyped =
  result = nnkTupleConstr.newNimNode()
  for i in 0 ..< len: result.add(elemType)

proc popElement*(stack: var Stack): StackElement {.inline.} =
  ensurePop(stack, 1)
  result = stack.elements[^1]
  stack.elements.setLen(stack.elements.len - 1)

proc popElements*(stack: var Stack, numItems: static[int]): auto {.inline.} =
  var r: genTupleType(numItems, StackElement)
  stack.internalPopElementsTuple(r, numItems)
  return r

proc popSeqOfElements*(stack: var Stack, numItems: int): seq[StackElement] {.inline.} =
  ensurePop(stack, numItems)
  let sz = stack.elements.high
  for i in 0 ..< numItems:
    result.add(stack.elements[sz - i])
  stack.elements.setLen(sz - numItems + 1)

template popAndMap*(stack: var Stack, lvalueA: untyped, body: untyped): StackElement =
  map(stack.popElement) do (lvalueA: UInt256) -> UInt256:
    body

template popAndCombine*(stack: var Stack, lvalueA: untyped, lvalueB: untyped, body: untyped): StackElement =
  combineAndApply(stack.popElements(2)) do (lvalueA, lvalueB: UInt256) -> UInt256:
    body

template popAndCombine*(stack: var Stack, lvalueA: untyped, lvalueB: untyped, lvalueC: untyped, body: untyped): StackElement =
  combineAndApply(stack.popElements(3)) do (lvalueA, lvalueB, lvalueC: UInt256) -> UInt256:
    body

proc newStack*(): Stack =
  new(result)
  result.elements = @[]

proc swap*(stack: var Stack, position: int) =
  ##  Perform a SWAP operation on the stack
  var idx = position + 1
  if idx < len(stack) + 1:
    (stack.elements[^1], stack.elements[^idx]) = (stack.elements[^idx], stack.elements[^1])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for SWAP{position}")

template getInt(x: int): int = x

proc dup*(stack: var Stack, position: int | UInt256) =
  ## Perform a DUP operation on the stack
  let position = position.getInt
  if position in 1 .. stack.len:
    stack.pushElement(stack.elements[^position])
  else:
    raise newException(InsufficientStack,
                      &"Insufficient stack items for DUP{position}")

proc peekElement*(stack: Stack): StackElement =
  stack.elements[^1]

proc peek*(stack: Stack): UInt256 =
  # This should be used only for testing purposes!
  unsafeGetAlreadyAvailableValue(peekElement(stack))

proc `$`*(elem: StackElement): string =
  let m = maybeAlreadyAvailableValueOf(elem)
  if m.isSome:
    $(m.get)
  else:
    "not yet available"

proc `$`*(stack: Stack): string =
  let elements = stack.elements.mapIt(&"  {$it}").join("\n")
  &"Stack:\n{elements}"

# FIXME-Adam: is it okay for this to be unsafe?
proc `[]`*(stack: Stack, i: BackwardsIndex, T: typedesc): T =
  ensurePop(stack, int(i))
  fromStackValue(unsafeGetAlreadyAvailableValue(stack.elements[i]), result)

proc replaceTopElement*(stack: Stack, newTopElem: StackElement) {.inline.} =
  stack.elements[^1] = newTopElem




# FIXME-Adam: These need to be removed, because calling waitFor is obviously
# not what we want. I'm only leaving them here for now to keep the compiler
# happy until we switch over to the new way.
#
# See oph_arithmetic.nim for examples of what to do instead. (Basically
# call cpt.popStackValues.) I haven't finished propagating that change
# through the rest of the code base. (At least not in this branch. I
# did it once, but then the bits rotted.)
proc popInt*(stack: var Stack): UInt256 =
  let elem = stack.popElement
  waitFor(elem.futureInt())

proc popAddress*(stack: var Stack): EthAddress =
  let elem = stack.popElement
  waitFor(elem.futureAddress())

proc popTopic*(stack: var Stack): Topic =
  let elem = stack.popElement
  waitFor(elem.futureTopic())

proc internalPopTuple(stack: var Stack, v: var tuple, tupleLen: static[int]) =
  ensurePop(stack, tupleLen)
  var i = 0
  let sz = stack.elements.high
  for f in fields(v):
    let elem = stack.elements[sz - i]
    # FIXME-Adam: terrible idea, waits after each one instead of waiting once for
    # all of them, but this is temporary code that will be deleted after we've
    # switched over to the new way.
    waitFor(discardFutureValue(futureStackValue(elem)))
    let v = unsafeGetAlreadyAvailableValue(elem)
    fromStackValue(v, f)
    inc i
  stack.elements.setLen(sz - tupleLen + 1)

proc popInt*(stack: var Stack, numItems: static[int]): auto {.inline.} =
  var r: genTupleType(numItems, UInt256)
  stack.internalPopTuple(r, numItems)
  return r
