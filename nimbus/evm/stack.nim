# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[macros],
  eth/common,
  ./evm_errors,
  ./interpreter/utils/utils_numeric

type
  EvmStackRef* = ref object
    values: seq[EvmStackElement]

  EvmStackElement = UInt256
  EvmStackInts = uint64 | uint | int | GasInt
  EvmStackBytes32 = array[32, byte]

func len*(stack: EvmStackRef): int {.inline.} =
  len(stack.values)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template toStackElem(v: UInt256, elem: EvmStackElement) =
  elem = v

template toStackElem(v: EvmStackInts, elem: EvmStackElement) =
  elem = v.u256

template toStackElem(v: EthAddress, elem: EvmStackElement) =
  elem.initFromBytesBE(v)

template toStackElem(v: MDigest, elem: EvmStackElement) =
  elem.initFromBytesBE(v.data)

template toStackElem(v: openArray[byte], elem: EvmStackElement) =
  doAssert(v.len <= 32)
  elem.initFromBytesBE(v)

template fromStackElem(elem: EvmStackElement, _: type UInt256): UInt256 =
  elem

func fromStackElem(elem: EvmStackElement, _: type EthAddress): EthAddress =
  result[0 .. ^1] = elem.toBytesBE().toOpenArray(12, 31)

template fromStackElem(elem: EvmStackElement, _: type Hash256): Hash256 =
  Hash256(data: elem.toBytesBE())

template fromStackElem(elem: EvmStackElement, _: type EvmStackBytes32): EvmStackBytes32 =
  elem.toBytesBE()

func pushAux[T](stack: EvmStackRef, value: T): EvmResultVoid =
  if len(stack.values) > 1023:
    return err(stackErr(StackFull))
  stack.values.setLen(stack.values.len + 1)
  toStackElem(value, stack.values[^1])
  ok()

func ensurePop(stack: EvmStackRef, expected: int): EvmResultVoid =
  if stack.values.len < expected:
    return err(stackErr(StackInsufficient))
  ok()

func popAux(stack: EvmStackRef, T: type): EvmResult[T] =
  ? ensurePop(stack, 1)
  result = ok(fromStackElem(stack.values[^1], T))
  stack.values.setLen(stack.values.len - 1)

func internalPopTuple(stack: EvmStackRef, T: type, tupleLen: static[int]): EvmResult[T] =
  ? ensurePop(stack, tupleLen)
  var
    i = 0
    v: T
  let sz = stack.values.high
  for f in fields(v):
    f = fromStackElem(stack.values[sz - i], UInt256)
    inc i
  stack.values.setLen(sz - tupleLen + 1)
  ok(v)

macro genTupleType(len: static[int], elemType: untyped): untyped =
  result = nnkTupleConstr.newNimNode()
  for i in 0 ..< len: result.add(elemType)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func push*(stack: EvmStackRef,
           value: EvmStackInts | UInt256 | EthAddress | Hash256): EvmResultVoid =
  pushAux(stack, value)

func push*(stack: EvmStackRef, value: openArray[byte]): EvmResultVoid =
  pushAux(stack, value)

func popInt*(stack: EvmStackRef): EvmResult[UInt256] =
  popAux(stack, UInt256)

func popSafeInt*(stack: EvmStackRef): EvmResult[int] =
  ? ensurePop(stack, 1)
  result = ok(fromStackElem(stack.values[^1], UInt256).safeInt)
  stack.values.setLen(stack.values.len - 1)

func popMemRef*(stack: EvmStackRef): EvmResult[int] =
  ? ensurePop(stack, 1)
  result = ok(fromStackElem(stack.values[^1], UInt256).cleanMemRef)
  stack.values.setLen(stack.values.len - 1)

func popInt*(stack: EvmStackRef, numItems: static[int]): auto =
  type T = genTupleType(numItems, UInt256)
  stack.internalPopTuple(T, numItems)

func popAddress*(stack: EvmStackRef): EvmResult[EthAddress] =
  popAux(stack, EthAddress)

func popTopic*(stack: EvmStackRef): EvmResult[EvmStackBytes32] =
  popAux(stack, EvmStackBytes32)

func new*(_: type EvmStackRef): EvmStackRef =
  new(result)
  result.values = @[]

func swap*(stack: EvmStackRef, position: int): EvmResultVoid =
  ##  Perform a SWAP operation on the stack
  let idx = position + 1
  if idx < stack.values.len + 1:
    (stack.values[^1], stack.values[^idx]) = (stack.values[^idx], stack.values[^1])
    ok()
  else:
    err(stackErr(StackInsufficient))

func dup*(stack: EvmStackRef, position: int): EvmResultVoid =
  ## Perform a DUP operation on the stack
  if position in 1 .. stack.len:
    stack.push(stack.values[^position])
  else:
    err(stackErr(StackInsufficient))

func peek*(stack: EvmStackRef): EvmResult[UInt256] =
  if stack.values.len == 0:
    return err(stackErr(StackInsufficient))
  ok(fromStackElem(stack.values[^1], UInt256))

func peekSafeInt*(stack: EvmStackRef): EvmResult[int] =
  if stack.values.len == 0:
    return err(stackErr(StackInsufficient))
  ok(fromStackElem(stack.values[^1], UInt256).safeInt)

func `[]`*(stack: EvmStackRef, i: BackwardsIndex, T: typedesc): EvmResult[T] =
  ? ensurePop(stack, int(i))
  ok(fromStackElem(stack.values[i], T))

func peekInt*(stack: EvmStackRef): EvmResult[UInt256] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack.values[^1], Uint256))

func peekAddress*(stack: EvmStackRef): EvmResult[EthAddress] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack.values[^1], EthAddress))

func top*(stack: EvmStackRef,
          value: EvmStackInts | UInt256 | EthAddress | Hash256): EvmResultVoid =
  if stack.values.len == 0:
    return err(stackErr(StackInsufficient))
  toStackElem(value, stack.values[^1])
  ok()

iterator items*(stack: EvmStackRef): UInt256 =
  for v in stack.values:
    yield v

iterator pairs*(stack: EvmStackRef): (int, UInt256) =
  for i, v in stack.values:
    yield (i, v)
