# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/[json, strutils],
  stint,
  stew/byteutils,
  eth/common/block_access_lists

export
  json,
  block_access_lists

func stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 2 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

func `@@`[T](list: openArray[T]): JsonNode

func `@@`(x: Address): JsonNode =
  %(x.to0xHex)

func `@@`(x: Bytes): JsonNode =
  %("0x" & x.toHex)

func `@@`(x: uint16 | uint32 | uint64): JsonNode =
  %("0x" & x.toHex.stripLeadingZeros)

func `@@`(x: UInt256): JsonNode =
  let hex = x.toHex
  if hex.len mod 2 != 0: %("0x0" & hex)
  else: %("0x" & hex)

func `@@`(x: NonceChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postNonce": @@(x.newNonce),
  }

func `@@`(x: BalanceChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postBalance": @@(x.postBalance),
  }

func `@@`(x: CodeChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "newCode": @@(x.newCode),
  }

func `@@`(x: StorageChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postValue": @@(x.newValue),
  }

func `@@`(x: SlotChanges): JsonNode =
  result = %{
    "slot": @@(x.slot),
    "slotChanges": @@(x.changes),
  }

func `@@`[T](list: openArray[T]): JsonNode =
  result = newJArray()
  for x in list:
    result.add @@(x)

func `@@`*(x: AccountChanges): JsonNode =
  result = %{
    "address"       : @@(x.address),
    "nonceChanges"  : @@(x.nonceChanges),
    "balanceChanges": @@(x.balanceChanges),
    "codeChanges"   : @@(x.codeChanges),
    "storageChanges": @@(x.storageChanges),
    "storageReads"  : @@(x.storageReads),
  }

func `@@`*(bal: BlockAccessListRef): JsonNode =
  result = newJArray()
  for x in bal[]:
    result.add @@(x)
