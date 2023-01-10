# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  stew/bitseqs,
  ./hardforks

type
  EIP* = enum
    EIP3540 # EVM Object Format (EOF) v1
    EIP3651 # Warm COINBASE
    EIP3670 # EOF - Code Validation
    EIP3855 # PUSH0 instruction
    EIP3860 # Limit and meter initcode
    EIP4200 # EOF - Static relative jumps
    EIP4750 # EOF - Functions
    EIP4895 # Beacon chain push withdrawals as operations
    EIP5450 # EOF - Stack Validation

template len(x: type EIP): int =
  1+EIP.high.int

type
  EipSet* = BitArray[EIP.len]
  ForkToEIP* = array[HardFork, EipSet]

proc incl*(x: var EipSet, y: EipSet) =
  for i in 0..<x.bytes.len:
    x.bytes[i] = x.bytes[i] or y.bytes[i]

proc incl*(x: var EipSet, y: EIP) =
  x.setBit(y.int)

proc incl*(x: var EipSet, y: openArray[EIP]) =
  for z in y:
    x.incl z

proc excl*(x: var EipSet, y: EipSet) =
  for i in 0..<x.bytes.len:
    x.bytes[i] = x.bytes[i] and not y.bytes[i]

proc excl*(x: var EipSet, y: EIP) =
  x.clearBit(y.int)

proc excl*(x: var EipSet, y: openArray[EIP]) =
  for z in y:
    x.excl z

func contains*(x: EipSet, y: EIP): bool =
  x[y.int]

func eipSet*(y: openArray[EIP]): EipSet =
  for z in y:
    result.incl z

func eipSet*(y: varargs[EIP]): EipSet =
  for z in y:
    result.incl z

func makeForkToEIP(): ForkToEIP {.compileTime.} =
  var map: ForkToEIP

  map[Shanghai] = eipSet(
    EIP3540, # EVM Object Format (EOF) v1
    EIP3651, # Warm COINBASE
    EIP3670, # EOF - Code Validation
    EIP3855, # PUSH0 instruction
    EIP3860, # Limit and meter initcode
    EIP4200, # EOF - Static relative jumps
    EIP4750, # EOF - Functions
    EIP4895, # Beacon chain push withdrawals as operations
    EIP5450, # EOF - Stack Validation
  )

  # the latest fork will accumulate most EIPs
  for fork in HardFork:
    result[fork] = map[fork]
    if fork > Frontier:
      result[fork].incl map[pred(fork)]

const
  ForkToEipList* = makeForktoEip()
