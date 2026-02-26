# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, tables, strutils],
  stint,
  eth/common/[base, addresses, hashes],
  stew/byteutils,
  ../db/ledger

type
  DumpAccount* = ref object
    balance* : UInt256
    nonce*   : AccountNonce
    root*    : Hash32
    codeHash*: Hash32
    code*    : seq[byte]
    key*     : Hash32
    storage* : Table[UInt256, UInt256]

  StateDump* = ref object
    root*: Hash32
    accounts*: Table[Address, DumpAccount]

proc `%`*(x: UInt256): JsonNode =
  %("0x" & x.toHex)

proc `%`*(x: seq[byte]): JsonNode =
  %("0x" & x.toHex)

proc `%`*(x: Hash32): JsonNode =
  %("0x" & x.data.toHex)

proc `%`*(x: AccountNonce): JsonNode =
  %("0x" & x.toHex)

proc `%`*(x: Table[UInt256, UInt256]): JsonNode =
  result = newJObject()
  for k, v in x:
    result["0x" & k.toHex] = %(v)

proc `%`*(x: DumpAccount): JsonNode =
  result = %{
    "balance" : %(x.balance),
    "nonce"   : %(x.nonce),
    "root"    : %(x.root),
    "codeHash": %(x.codeHash),
    "code"    : %(x.code),
    "key"     : %(x.key)
  }
  if x.storage.len > 0:
    result["storage"] = %(x.storage)

proc `%`*(x: Table[Address, DumpAccount]): JsonNode =
  result = newJObject()
  for k, v in x:
    result["0x" & k.toHex] = %(v)

proc `%`*(x: StateDump): JsonNode =
  result = %{
    "root": %(x.root),
    "accounts": %(x.accounts)
  }

proc dumpAccount(ledger: LedgerRef, acc: Address): DumpAccount =
  result = DumpAccount(
    balance : ledger.getBalance(acc),
    nonce   : ledger.getNonce(acc),
    root    : ledger.getStorageRoot(acc),
    codeHash: ledger.getCodeHash(acc),
    code    : ledger.getCode(acc).bytes(),
    key     : keccak256(acc.data)
  )
  for k, v in ledger.cachedStorage(acc):
    result.storage[k] = v

proc dumpAccounts*(ledger: LedgerRef): Table[Address, DumpAccount] =
  for acc in ledger.addresses():
    result[acc] = dumpAccount(ledger, acc)

proc dumpState*(ledger: LedgerRef): StateDump =
  StateDump(
    root: ledger.getStateRoot(),
    accounts: dumpAccounts(ledger)
  )

proc dumpAccounts*(ledger: LedgerRef, addresses: openArray[Address]): JsonNode =
  result = newJObject()
  for address in addresses:
    result[address.toHex] = %dumpAccount(ledger, address)

