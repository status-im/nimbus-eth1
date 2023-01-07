# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  interpreter/op_codes,
  ../common/evmforks

type
  StackDesc* = object
    min*: int
    max*: int
    enabled*: bool

  StackTable* = array[Op, StackDesc]

const
  StackLimit* = 1024

func maxStack(pop, push: int): int {.compileTime.} =
  StackLimit + pop - push

func minStack(pops, push: int): int {.compileTime.} =
  pops

func minSwapStack(n: int): int {.compileTime.} =
  minStack(n, n)

func maxSwapStack(n: int): int {.compileTime.} =
  maxStack(n, n)

func minDupStack(n: int): int {.compileTime.} =
  minStack(n, n+1)

func maxDupStack(n: int): int {.compileTime.}  =
  maxStack(n, n+1)

template sm(op: Op, a, b: int): untyped =
  (op, StackDesc(
    min: minStack(a, b),
    max: maxStack(a, b),
    enabled: true)
  )

template sp(a, b: int): untyped =
  StackDesc(
    min: minStack(a, b),
    max: maxStack(a, b),
    enabled: true
  )

template sd(x: int): untyped =
  StackDesc(
    min: minDupStack(x),
    max: maxDupStack(x),
    enabled: true
  )

template ss(x: int): untyped =
  StackDesc(
    min: minSwapStack(x),
    max: maxSwapStack(x),
    enabled: true
  )

const
  BaseStackTable = [
    sm(Stop,         0, 0),
    sm(Add,          2, 1),
    sm(Mul,          2, 1),
    sm(Sub,          2, 1),
    sm(Div,          2, 1),
    sm(Sdiv,         2, 1),
    sm(Mod,          2, 1),
    sm(Smod,         2, 1),
    sm(Addmod,       3, 1),
    sm(Mulmod,       3, 1),
    sm(Exp,          2, 1),
    sm(SignExtend,   2, 1),
    sm(Lt,           2, 1),
    sm(Gt,           2, 1),
    sm(Slt,          2, 1),
    sm(Sgt,          2, 1),
    sm(Eq,           2, 1),
    sm(IsZero,       1, 1),
    sm(And,          2, 1),
    sm(Or,           2, 1),
    sm(Xor,          2, 1),
    sm(Not,          1, 1),
    sm(Byte,         2, 1),
    sm(Sha3,         2, 1),
    sm(Address,      0, 1),
    sm(Balance,      1, 1),
    sm(Origin,       0, 1),
    sm(Caller,       0, 1),
    sm(CallValue,    0, 1),
    sm(CallDataLoad, 1, 1),
    sm(CallDataSize, 0, 1),
    sm(CallDataCopy, 3, 0),
    sm(CodeSize,     0, 1),
    sm(CodeCopy,     3, 0),
    sm(GasPrice,     0, 1),
    sm(ExtCodeSize,  1, 1),
    sm(ExtCodeCopy,  4, 0),
    sm(Blockhash,    1, 1),
    sm(Coinbase,     0, 1),
    sm(Timestamp,    0, 1),
    sm(Number,       0, 1),
    sm(Difficulty,   0, 1),
    sm(GasLimit,     0, 1),
    sm(Pop,          1, 0),
    sm(Mload,        1, 1),
    sm(Mstore,       2, 0),
    sm(Mstore8,      2, 0),
    sm(Sload,        1, 1),
    sm(Sstore,       2, 0),
    sm(Jump,         1, 0),
    sm(JumpI,        2, 0),
    sm(Pc,           0, 1),
    sm(Msize,        0, 1),
    sm(Gas,          0, 1),
    sm(JumpDest,     0, 0),
    sm(Log0,         2, 0),
    sm(Log1,         3, 0),
    sm(Log2,         4, 0),
    sm(Log3,         5, 0),
    sm(Log4,         6, 0),
    sm(Create,       3, 1),
    sm(Call,         7, 1),
    sm(CallCode,     7, 1),
    sm(Return,       2, 0),
    sm(SelfDestruct, 1, 0),
    sm(Invalid,      0, 0),
  ]

proc frontierStackTable(): StackTable {.compileTime.} =
  for x in BaseStackTable:
    result[x[0]] = x[1]

  for x in Push1..Push32:
    result[x] = sp(0, 1)

  for x in Dup1..Dup16:
    result[x] = sd(x.int-Dup1.int+1)

  for x in Swap1..Swap16:
    result[x] = ss(x.int-Swap1.int+2)

proc homesteadStackTable(): StackTable {.compileTime.} =
  result = frontierStackTable()
  result[DelegateCall] = sp(6, 1)

proc byzantiumStackTable(): StackTable {.compileTime.}  =
  result = homesteadStackTable()
  result[StaticCall]     = sp(6, 1)
  result[ReturnDataSize] = sp(0, 1)
  result[ReturnDataCopy] = sp(3, 0)
  result[Revert]         = sp(2, 0)

proc constantinopleStackTable(): StackTable {.compileTime.} =
  result = byzantiumStackTable()
  result[Shl] = sp(2, 1)
  result[Shr] = sp(2, 1)
  result[Sar] = sp(2, 1)
  result[ExtCodeHash] = sp(1, 1)
  result[Create2] = sp(4, 1)

proc istanbulStackTable(): StackTable {.compileTime.} =
  result = constantinopleStackTable()
  # new opcodes EIP-1344
  result[ChainIdOp] = sp(0, 1)
  # new opcodes EIP-1884
  result[SelfBalance] = sp(0, 1)

proc londonStackTable(): StackTable {.compileTime.} =
  result = istanbulStackTable()
  # new opcodes EIP-3198
  result[BaseFee] = sp(0, 1)

proc mergeStackTable(): StackTable {.compileTime.} =
  result = londonStackTable()
  result[PrevRandao] = sp(0, 1)

proc cancunStackTable(): StackTable {.compileTime.} =
  result = mergeStackTable()
  # new opcodes EIP-4200
  result[Rjump]  = sp(0, 0)
  result[RJumpI] = sp(1, 0)
  result[RJumpV] = sp(1, 0)
  # new opcodes EIP-4750
  result[CallF]  = sp(0, 0)
  result[RetF]   = sp(0, 0)
  # new opcodes EIP-3855
  result[Push0]  = sp(0, 1)

  # disable opcodes EIP-3670
  result[CallCode]     = StackDesc()
  result[SelfDestruct] = StackDesc()
  # disable opcodes EIP-5450
  result[Jump]         = StackDesc()
  result[JumpI]        = StackDesc()
  result[Pc]           = StackDesc()

const
  EVMForksStackTable*: array[EVMFork, StackTable] = [
    frontierStackTable(),
    homesteadStackTable(),
    homesteadStackTable(),
    homesteadStackTable(),
    byzantiumStackTable(),
    constantinopleStackTable(),
    constantinopleStackTable(),
    istanbulStackTable(),
    istanbulStackTable(),
    londonStackTable(),
    mergeStackTable(),
    mergeStackTable(),
    cancunStackTable(),
  ]
