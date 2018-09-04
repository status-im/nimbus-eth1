# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, strformat, tables,
  chronicles, eth_common, nimcrypto, rlp, eth_trie/[hexary, memdb],
  ../constants, ../errors, ../validation, ../account

logScope:
  topics = "state_db"

type
  AccountStateDB* = ref object
    trie: SecureHexaryTrie

proc rootHash*(accountDb: AccountStateDB): KeccakHash =
  accountDb.trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
# TODO: self.Trie.rootHash = value

proc newAccountStateDB*(backingStore: TrieDatabaseRef,
                        root: KeccakHash, readOnly: bool = false): AccountStateDB =
  result.new()
  result.trie = initSecureHexaryTrie(backingStore, root)

template createRangeFromAddress(address: EthAddress): ByteRange =
  ## XXX: The name of this proc is intentionally long, because it
  ## performs a memory allocation and data copying that may be eliminated
  ## in the future. Avoid renaming it to something similar as `toRange`, so
  ## it can remain searchable in the code.
  toRange(@address)

proc getAccount(db: AccountStateDB, address: EthAddress): Account =
  let recordFound = db.trie.get(createRangeFromAddress address)
  if recordFound.len > 0:
    result = rlp.decode(recordFound, Account)
  else:
    result = newAccount()

proc setAccount*(db: AccountStateDB, address: EthAddress, account: Account) =
  db.trie.put createRangeFromAddress(address), rlp.encode(account)

proc getCodeHash*(db: AccountStateDB, address: EthAddress): Hash256 =
  let account = db.getAccount(address)
  result = account.codeHash

proc getBalance*(db: AccountStateDB, address: EthAddress): UInt256 =
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: var AccountStateDB, address: EthAddress, balance: UInt256) =
  var account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)

template createTrieKeyFromSlot(slot: UInt256): ByteRange =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  @(slot.toByteArrayBE).toRange
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

template getAccountTrie(stateDb: AccountStateDB, account: Account): auto =
  initSecureHexaryTrie(HexaryTrie(stateDb.trie).db, account.storageRoot)

proc setStorage*(db: var AccountStateDB,
                 address: EthAddress,
                 slot: UInt256, value: UInt256) =
  #validateGte(value, 0, title="Storage Value")
  #validateGte(slot, 0, title="Storage Slot")

  var account = db.getAccount(address)
  var accountTrie = getAccountTrie(db, account)
  let slotAsKey = createTrieKeyFromSlot slot

  if value > 0:
    let encodedValue = rlp.encode value
    accountTrie.put(slotAsKey, encodedValue)
  else:
    accountTrie.del(slotAsKey)

  account.storageRoot = accountTrie.rootHash
  db.setAccount(address, account)

proc getStorage*(db: AccountStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) =
  let
    account = db.getAccount(address)
    slotAsKey = createTrieKeyFromSlot slot
    accountTrie = getAccountTrie(db, account)

  let
    foundRecord = accountTrie.get(slotAsKey)

  if foundRecord.len > 0:
    result = (rlp.decode(foundRecord, UInt256), true)
  else:
    result = (0.u256, false)

proc setNonce*(db: var AccountStateDB, address: EthAddress, newNonce: AccountNonce) =
  var account = db.getAccount(address)
  if newNonce != account.nonce:
    account.nonce = newNonce
    db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: EthAddress): AccountNonce =
  let account = db.getAccount(address)
  account.nonce

proc toByteRange_Unnecessary*(h: KeccakHash): ByteRange =
  ## XXX: Another proc used to mark unnecessary conversions it the code
  var s = @(h.data)
  return s.toRange

proc setCode*(db: var AccountStateDB, address: EthAddress, code: ByteRange) =
  var account = db.getAccount(address)
  let newCodeHash = keccak256.digest code.toOpenArray
  if newCodeHash != account.codeHash:
    account.codeHash = newCodeHash
    # XXX: this uses the journaldb in py-evm
    # Breaks state hash root calculations
    # db.trie.put(account.codeHash.toByteRange_Unnecessary, code)
    db.setAccount(address, account)

proc getCode*(db: AccountStateDB, address: EthAddress): ByteRange =
  let codeHash = db.getCodeHash(address)
  result = db.trie.get(codeHash.toByteRange_Unnecessary)

proc dumpAccount*(db: AccountStateDB, addressS: string): string =
  let address = addressS.parseAddress
  return fmt"{addressS}: Storage: {db.getStorage(address, 0.u256)}; getAccount: {db.getAccount address}"
