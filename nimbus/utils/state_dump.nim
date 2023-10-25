# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
  eth/common/eth_types,
  stew/byteutils,
  ../db/ledger

type
  DumpAccount* = ref object
    balance* : UInt256
    nonce*   : AccountNonce
    root*    : Hash256
    codeHash*: Hash256
    code*    : Blob
    key*     : Hash256
    storage* : Table[UInt256, UInt256]

  StateDump* = ref object
    root*: Hash256
    accounts*: Table[EthAddress, DumpAccount]

proc `%`*(x: UInt256): JsonNode =
  %("0x" & x.toHex)

proc `%`*(x: Blob): JsonNode =
  %("0x" & x.toHex)

proc `%`*(x: Hash256): JsonNode =
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

proc `%`*(x: Table[EthAddress, DumpAccount]): JsonNode =
  result = newJObject()
  for k, v in x:
    result["0x" & k.toHex] = %(v)

proc `%`*(x: StateDump): JsonNode =
  result = %{
    "root": %(x.root),
    "accounts": %(x.accounts)
  }

proc dumpAccount*(db: LedgerRef, acc: EthAddress): DumpAccount =
  result = DumpAccount(
    balance : db.getBalance(acc),
    nonce   : db.getNonce(acc),
    root    : db.getStorageRoot(acc),
    codeHash: db.getCodeHash(acc),
    code    : db.getCode(acc),
    key     : keccakHash(acc)
  )
  for k, v in db.cachedStorage(acc):
    result.storage[k] = v

proc dumpAccounts*(db: LedgerRef): Table[EthAddress, DumpAccount] =
  for acc in db.addresses():
    result[acc] = dumpAccount(db, acc)

proc dumpState*(db: LedgerRef): StateDump =
  StateDump(
    root: db.rootHash,
    accounts: dumpAccounts(db)
  )

proc dumpAccounts*(stateDB: LedgerRef, addresses: openArray[EthAddress]): JsonNode =
  result = newJObject()
  for ac in addresses:
    result[ac.toHex] = %dumpAccount(stateDB, ac)

