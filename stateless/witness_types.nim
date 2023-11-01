# Nimbus
# Copyright (c) 2020-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import stew/bitops2

{.push raises: [].}

type
  TrieNodeType* = enum
    BranchNodeType
    ExtensionNodeType
    AccountNodeType
    HashNodeType

  AccountType* = enum
    SimpleAccountType
    ExtendedAccountType

  BytecodeType* = enum
    CodeTouched
    CodeUntouched

  WitnessFlag* = enum
    wfNoFlag
    wfEIP170 # fork >= Spurious Dragon

  MetadataType* = enum
    MetadataNothing
    MetadataSomething

  WitnessFlags* = set[WitnessFlag]

  ContractCodeError* = object of ValueError
  ParsingError* = object of ValueError

  StorageSlot* = array[32, byte]

const
  StorageLeafNodeType* = AccountNodeType
  BlockWitnessVersion* = 0x01
  ShortRlpPrefix*      = 0.byte

proc setBranchMaskBit*(x: var uint, i: int) =
  assert(i >= 0 and i < 17)
  x = x or (1 shl i).uint

func branchMaskBitIsSet*(x: uint, i: int): bool =
  assert(i >= 0 and i < 17)
  result = ((x shr i.uint) and 1'u) == 1'u

func constructBranchMask*(b1, b2: byte): uint
    {.gcsafe, raises: [ParsingError].} =
  result = uint(b1) shl 8 or uint(b2)
  if countOnes(result) < 2 or ((result and (not 0x1FFFF'u)) != 0):
    raise newException(ParsingError, "Invalid branch mask pattern " & $result)

iterator nonEmpty*(branchMask: uint): int =
  for i in 0..<16:
    if not branchMask.branchMaskBitIsSet(i):
      # we skip an empty elem
      continue
    yield i
