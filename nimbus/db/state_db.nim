# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common, tables,
  ../constants, ../errors, ../validation, ../account, ../logging, ../utils_numeric, .. / utils / [padding, bytes, keccak],
  stint, rlp

type
  AccountStateDB* = ref object
    db*: Table[string, BytesRange]
    rootHash*: Hash256 # TODO trie

proc newAccountStateDB*(db: Table[string, string], readOnly: bool = false): AccountStateDB =
  result = AccountStateDB(db: initTable[string, BytesRange]())

proc logger*(db: AccountStateDB): Logger =
  logging.getLogger("db.State")

proc getAccount(db: AccountStateDB, address: EthAddress): Account =
  # let rlpAccount = db.trie[address]
  # if not rlpAccount.isNil:
  #   account = rlp.decode[Account](rlpAccount)
  #   account.mutable = true
  # else:
  #   account = newAccount()
  result = newAccount() # TODO

proc setAccount(db: AccountStateDB, address: EthAddress, account: Account) =
  # db.trie[address] = rlp.encode[Account](account)
  discard # TODO


proc getCodeHash*(db: AccountStateDB, address: EthAddress): Hash256 =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  result = account.codeHash

proc getBalance*(db: AccountStateDB, address: EthAddress): UInt256 =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: var AccountStateDB, address: EthAddress, balance: UInt256) =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)


proc setStorage*(db: var AccountStateDB, address: EthAddress, slot: UInt256, value: UInt256) =
  #validateGte(value, 0, title="Storage Value")
  #validateGte(slot, 0, title="Storage Slot")
  validateCanonicalAddress(address, title="Storage Address")

  # TODO
  # let account = db.getAccount(address)
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  let slotAsKey = slot.intToBigEndian.pad32.toString
  var storage = db.db
  # TODO fix
  if value > 0:
    let encodedValue = rlp.encode value.intToBigEndian
    storage[slotAsKey] = encodedValue
  else:
    storage.del(slotAsKey)
  #storage[slotAsKey] = value
  # account.storageRoot = storage.rootHash
  # db.setAccount(address, account)

proc getStorage*(db: var AccountStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) =
  validateCanonicalAddress(address, title="Storage Address")
  #validateGte(slot, 0, title="Storage Slot")

  # TODO
  # make it more correct
  # for now, we just use a table

  # let account = db.GetAccount(address)
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  let slotAsKey = slot.intToBigEndian.pad32.toString
  var storage = db.db
  if storage.hasKey(slotAsKey):
    #result = storage[slotAsKey]
    # XXX: `bigEndianToInt` can be refactored to work with a BytesRange/openarray
    # Then we won't need to call `toSeq` here.
    result = (storage[slotAsKey].toSeq.bigEndianToInt, true)
  else:
    result = (0.u256, false)

proc setNonce*(db: var AccountStateDB, address: EthAddress, nonce: UInt256) =
  validateCanonicalAddress(address, title="Storage Address")
  #validateGte(nonce, 0, title="Nonce")

  var account = db.getAccount(address)
  account.nonce = nonce

  db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: EthAddress): UInt256 =
  validateCanonicalAddress(address, title="Storage Address")

  let account = db.getAccount(address)
  return account.nonce

proc setCode*(db: var AccountStateDB, address: EthAddress, code: string) =
  validateCanonicalAddress(address, title="Storage Address")

  var account = db.getAccount(address)

  account.codeHash = keccak(code)
  #db.db[account.codeHash] = code
  db.setAccount(address, account)

proc getCode*(db: var AccountStateDB, address: EthAddress): string =
  let codeHash = db.getCodeHash(address)
  #if db.db.hasKey(codeHash):
  #  result = db.db[codeHash]
  #else:
  result = ""

# proc rootHash*(db: AccountStateDB): string =
  # TODO return self.Trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
  # TODO: self.Trie.rootHash = value
