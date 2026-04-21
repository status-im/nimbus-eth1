# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils],
  stint,
  stew/byteutils,
  eth/common/block_access_lists

export
  json

template required(T: type, nField: string): auto =
  fromJson(T, n[nField])

template fromJson(T: type Address, n: JsonNode): Address =
  Address.fromHex(n.getStr)

template fromJson(T: type UInt256, n: JsonNode): UInt256 =
  UInt256.fromHex(n.getStr)

proc fromJson(T: type Bytes, n: JsonNode): T =
  let hex = n.getStr
  if hex.len == 0:
    @[]
  else:
    hexToSeqByte(hex)

template fromJson(T: type uint64, n: JsonNode): uint64 =
  fromHex[AccountNonce](n.getStr)

template fromJson(T: type uint32, n: JsonNode): uint32 =
  fromHex[uint32](n.getStr)

proc fromJson(T: type NonceChange, n: JsonNode): NonceChange =
  (
    required(uint32, "blockAccessIndex"),
    required(AccountNonce, "postNonce")
  )

proc fromJson(T: type BalanceChange, n: JsonNode): BalanceChange =
  (
    required(uint32, "blockAccessIndex"),
    required(UInt256, "postBalance")
  )

proc fromJson(T: type CodeChange, n: JsonNode): CodeChange =
  (
    required(uint32, "blockAccessIndex"),
    required(Bytes, "newCode")
  )

proc fromJson(T: type StorageChange, n: JsonNode): StorageChange =
  (
    required(uint32, "blockAccessIndex"),
    required(UInt256, "postValue")
  )

proc fromJson[T](LT: type seq[T], list: JsonNode): LT =
  mixin fromJson
  for x in list:
    result.add T.fromJson(x)
    
proc fromJson(T: type SlotChanges, n: JsonNode): SlotChanges =
  (
    required(UInt256, "slot"),
    required(seq[StorageChange], "slotChanges")
  )

proc fromJson(T: type AccountChanges, n: JsonNode): AccountChanges =
  AccountChanges(
    address:        required(Address, "address"),
    nonceChanges:   required(seq[NonceChange], "nonceChanges"),
    balanceChanges: required(seq[BalanceChange], "balanceChanges"),
    codeChanges:    required(seq[CodeChange], "codeChanges"),
    storageChanges: required(seq[SlotChanges], "storageChanges"),
    storageReads:   required(seq[UInt256], "storageReads"),
  )

proc balFromJson*(n: JsonNode): BlockAccessList =
  result = newSeqOfCap[AccountChanges](n.len)
  for x in n:
    result.add AccountChanges.fromJson(x)
