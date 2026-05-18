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
  json

proc `@@`[T](list: openArray[T]): JsonNode

proc `@@`(x: Address): JsonNode =
  %(x.to0xHex)

proc `@@`(x: Bytes): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: uint16 | uint32 | uint64): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: UInt256): JsonNode =
  %("0x" & x.toHex)

proc `@@`(x: NonceChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postNonce": @@(x.newNonce),
  }

proc `@@`(x: BalanceChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postBalance": @@(x.postBalance),
  }

proc `@@`(x: CodeChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "newCode": @@(x.newCode),
  }

proc `@@`(x: StorageChange): JsonNode =
  result = %{
    "blockAccessIndex": @@(x.blockAccessIndex),
    "postValue": @@(x.newValue),
  }

proc `@@`(x: SlotChanges): JsonNode =
  result = %{
    "slot": @@(x.slot),
    "slotChanges": @@(x.changes),
  }

proc `@@`[T](list: openArray[T]): JsonNode =
  result = newJArray()
  for x in list:
    result.add @@(x)

proc toJson*(x: AccountChanges): JsonNode =
  result = %{
    "address"       : @@(x.address),
    "nonceChanges"  : @@(x.nonceChanges),
    "balanceChanges": @@(x.balanceChanges),
    "codeChanges"   : @@(x.codeChanges),
    "storageChanges": @@(x.storageChanges),
    "storageReads"  : @@(x.storageReads),
  }

proc toJson*(bal: BlockAccessList): JsonNode =
  result = newJArray()
  for x in bal:
    result.add x.toJson()
