# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Type managing the EVM stack that comprises of 1024 256-bit words.
#
# The stack is a hot spot in EVM execution since it's used for practically every
# opcode. We use custom-allocated memory for several reasons, chiefly
# performance (at the time of writing, using a seq carried about 5% overhead on
# total EVM execution time):
#
# * no zeromem - the way the EVM uses the stack, it always writes full words
#   meaning that whatever zeroing was done gets overwritten anyway - compilers
#   are typically not smart enough to get rid of all of this
# * no reallocation - since we can allocate memory without zeroing, we can
#   allocate the full stack length on creation and never grow / reallocate
# * less redundant range checking - we have to perform range checks manually and
#   the compiler is not able to remove them consistently even though we range
#   check manually
# * 32-byte alignment helps vector instruction optimization
#
# After calling `init`, the stack must be freed manually using `dispose`!

{.push raises: [].}

import
  system/ansi_c,
  stew/[assign2, ptrops],
  stint,
  eth/common/[base, addresses, hashes],
  std/typetraits,
  ./evm_errors,
  ./interpreter/utils/utils_numeric

const evmStackSize = 1024
  ## https://ethereum.org/en/developers/docs/evm/#evm-instructions

type
  EvmStack* = ref object
    values: ptr EvmStackElement
    memory: pointer
    len*: int

  EvmStackElement = object
    data {.align: 32.}: UInt256

  EvmStackInts = uint64 | uint | int | GasInt

static:
  # A few sanity checks because we skip the GC / parts of the nim type system:
  doAssert sizeof(UInt256) == 32, "no padding etc"
  doAssert supportsCopyMem(EvmStackElement), "byte-based ops must work sanely"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template `[]`*(s: EvmStack, i: int): EvmStackElement =
  s.values.offset(i)[]

template `[]`*(s: EvmStack, i: BackwardsIndex): EvmStackElement =
  s.values.offset(s.len - int(i))[]

template `[]=`*(s: EvmStack, i: int, v: EvmStackElement) =
  assign(s[i], v)

template `[]=`*(s: EvmStack, i: BackwardsIndex, v: EvmStackElement) =
  assign(s[i], v)

template toStackElem(v: EvmStackElement, elem: EvmStackElement) =
  elem = v

template toStackElem(v: UInt256, elem: EvmStackElement) =
  elem.data = v

template toStackElem(v: EvmStackInts, elem: EvmStackElement) =
  elem.data = v.u256

template toStackElem(v: Address, elem: EvmStackElement) =
  elem.data.initFromBytesBE(v.data)

template toStackElem(v: Hash32, elem: EvmStackElement) =
  elem.data.initFromBytesBE(v.data)

template toStackElem(v: openArray[byte], elem: EvmStackElement) =
  elem.data.initFromBytesBE(v)

template fromStackElem(elem: EvmStackElement, _: type UInt256): UInt256 =
  elem.data

func fromStackElem(elem: EvmStackElement, _: type Address): Address =
  elem.data.to(Bytes32).to(Address)

template fromStackElem(elem: EvmStackElement, _: type Hash32): Hash32 =
  Hash32(elem.data.toBytesBE())

template fromStackElem(elem: EvmStackElement, _: type Bytes32): Bytes32 =
  elem.data.toBytesBE().to(Bytes32)

func ensurePop(stack: EvmStack, expected: int): EvmResultVoid =
  if stack.len < expected:
    return err(stackErr(StackInsufficient))
  ok()

func popAux(stack: EvmStack, T: type): EvmResult[T] =
  ? ensurePop(stack, 1)
  stack.len -= 1
  ok(fromStackElem(stack[stack.len], T))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func push*(stack: EvmStack,
           value: EvmStackElement | EvmStackInts | UInt256 | Address | Hash32): EvmResultVoid =
  let len = stack.len
  if len > 1023:
    return err(stackErr(StackFull))
  toStackElem(value, stack[len])
  stack.len = len + 1
  ok()

func popInt*(stack: EvmStack): EvmResult[UInt256] =
  popAux(stack, UInt256)

func popAddress*(stack: EvmStack): EvmResult[Address] =
  popAux(stack, Address)

func pop*(stack: EvmStack): EvmResult[void] =
  ? ensurePop(stack, 1)
  stack.len -= 1
  ok()

proc init*(_: type EvmStack): EvmStack =
  let memory = c_malloc(evmStackSize * sizeof(EvmStackElement) + 31)

  EvmStack(
    values: cast[ptr EvmStackElement](((cast[uint](memory) + 31) div 32) * 32) ,
    memory: memory, # Need to free the same pointer that we got from malloc
    len: 0,
  )

proc dispose*(stack: EvmStack) =
  if stack[].memory != nil:
    c_free(stack[].memory)
    stack[].reset()

func swap*(stack: EvmStack, position: static int): EvmResultVoid =
  ## Swap the `top` and `top - position` items
  let
    idx = position + 1 # locals help compiler reason about overflows
    len = stack.len
  if stack.len >= idx:
    let
      l1 = len - 1
      li = len - idx
    let tmp {.noinit.} = stack[l1]
    stack[l1] = stack[li]
    stack[li] = tmp
    ok()
  else:
    err(stackErr(StackInsufficient))

func dup*(stack: EvmStack, position: int): EvmResultVoid =
  ## Push copy of item at `top - position`
  if position in 1 .. stack.len:
    stack.push(stack[^position])
  else:
    err(stackErr(StackInsufficient))

func peek*(stack: EvmStack): EvmResult[UInt256] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack[^1], UInt256))

func peekSafeInt*(stack: EvmStack): EvmResult[int] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack[^1], UInt256).safeInt)

func `[]`*(stack: EvmStack, i: BackwardsIndex, T: typedesc): EvmResult[T] =
  ? ensurePop(stack, int(i))
  ok(fromStackElem(stack[i], T))

func peekInt*(stack: EvmStack): EvmResult[UInt256] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack[^1], UInt256))

func peekAddress*(stack: EvmStack): EvmResult[Address] =
  ? ensurePop(stack, 1)
  ok(fromStackElem(stack[^1], Address))

func top*(stack: EvmStack,
          value: EvmStackInts | UInt256 | Address | Hash32): EvmResultVoid =
  ? ensurePop(stack, 1)
  toStackElem(value, stack[^1])
  ok()

iterator items*(stack: EvmStack): UInt256 =
  for i in 0..<stack.len:
    yield stack[i].data

iterator pairs*(stack: EvmStack): (int, UInt256) =
  for i in 0..<stack.len:
    yield (i, stack[i].data)

# ------------------------------------------------------------------------------
# Public functions with less safety
# ------------------------------------------------------------------------------

template lsCheck*(stack: EvmStack, expected: int): EvmResultVoid =
  ensurePop(stack, expected)

func lsTop*(stack: EvmStack,
            value: EvmStackInts | UInt256 | Address | Hash32) =
  toStackElem(value, stack[^1])

func lsTop*(stack: EvmStack, value: openArray[byte]) =
  toStackElem(value, stack[^1])

func lsPeekInt*(stack: EvmStack, i: BackwardsIndex): UInt256 =
  fromStackElem(stack[i], UInt256)

func lsPeekAddress*(stack: EvmStack, i: BackwardsIndex): Address =
  fromStackElem(stack[i], Address)

func lsPeekMemRef*(stack: EvmStack, i: BackwardsIndex): int =
  fromStackElem(stack[i], UInt256).cleanMemRef

func lsPeekSafeInt*(stack: EvmStack, i: BackwardsIndex): int =
  fromStackElem(stack[i], UInt256).safeInt

func lsPeekTopic*(stack: EvmStack, i: BackwardsIndex): Bytes32 =
  fromStackElem(stack[i], Bytes32)

func lsShrink*(stack: EvmStack, x: int) =
  stack.len -= x

template binaryOp*(stack: EvmStack, binOp): EvmResultVoid =
  let len = stack.len
  if len >= 2:
    let
      l1 = len - 1
      l2 = len - 2
    stack[l2].data = binOp(stack[l1].data, stack[l2].data)
    stack.len = l1
    EvmResultVoid.ok()
  else:
    EvmResultVoid.err(stackErr(StackInsufficient))

template unaryOp*(stack: EvmStack, unOp): EvmResultVoid =
  let len = stack.len
  if len >= 1:
    let l1 = len - 1
    stack[l1].data = unOp(stack[l1].data)
    EvmResultVoid.ok()
  else:
    EvmResultVoid.err(stackErr(StackInsufficient))

template binaryWithTop*(stack: EvmStack, binOp): EvmResultVoid =
  let len = stack.len
  if len >= 2:
    let
      l1 = len - 1
      l2 = len - 2
    binOp(stack[l2].data, stack[l1].data, stack[l2].data)
    stack.len = l1
    EvmResultVoid.ok()
  else:
    EvmResultVoid.err(stackErr(StackInsufficient))

template unaryWithTop*(stack: EvmStack, unOp): EvmResultVoid =
  let len = stack.len
  if len >= 1:
    let l1 = len - 1
    unOp(stack[l1], stack[l1].data, toStackElem)
    EvmResultVoid.ok()
  else:
    EvmResultVoid.err(stackErr(StackInsufficient))

template unaryAddress*(stack: EvmStack, unOp): EvmResultVoid =
  let len = stack.len
  if len >= 1:
    let l1 = len - 1
    let address = fromStackElem(stack[l1], Address)
    toStackElem(unOp(address), stack[l1])
    EvmResultVoid.ok()
  else:
    EvmResultVoid.err(stackErr(StackInsufficient))
