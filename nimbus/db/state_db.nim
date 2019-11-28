# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  chronicles, eth/[common, rlp], eth/trie/[hexary, db],
  ../constants, ../utils, storage_types

logScope:
  topics = "state_db"

type
  AccountStateDB* = ref object
    trie: SecureHexaryTrie
    originalRoot: KeccakHash   # will be updated for every transaction
    transactionID: TransactionID

  ReadOnlyStateDB* = distinct AccountStateDB

template trieDB(stateDB: AccountStateDB): TrieDatabaseRef =
  HexaryTrie(stateDB.trie).db

proc rootHash*(db: AccountStateDB): KeccakHash =
  db.trie.rootHash

proc `rootHash=`*(db: AccountStateDB, root: KeccakHash) =
  db.trie = initSecureHexaryTrie(trieDB(db), root, db.trie.isPruning)

proc newAccountStateDB*(backingStore: TrieDatabaseRef,
                        root: KeccakHash, pruneTrie: bool): AccountStateDB =
  result.new()
  result.trie = initSecureHexaryTrie(backingStore, root, pruneTrie)
  result.originalRoot = root
  result.transactionID = backingStore.getTransactionID()

template createRangeFromAddress(address: EthAddress): ByteRange =
  ## XXX: The name of this proc is intentionally long, because it
  ## performs a memory allocation and data copying that may be eliminated
  ## in the future. Avoid renaming it to something similar as `toRange`, so
  ## it can remain searchable in the code.
  toRange(@address)

proc getAccount*(db: AccountStateDB, address: EthAddress): Account =
  let recordFound = db.trie.get(createRangeFromAddress address)
  if recordFound.len > 0:
    result = rlp.decode(recordFound, Account)
  else:
    result = newAccount()

proc setAccount*(db: AccountStateDB, address: EthAddress, account: Account) =
  db.trie.put createRangeFromAddress(address), rlp.encode(account).toRange

proc deleteAccount*(db: AccountStateDB, address: EthAddress) =
  db.trie.del createRangeFromAddress(address)

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

proc addBalance*(db: var AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)

proc subBalance*(db: var AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) - delta)

template createTrieKeyFromSlot(slot: UInt256): ByteRange =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  @(slot.toByteArrayBE).toRange
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

template getAccountTrie(db: AccountStateDB, account: Account): auto =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initSecureHexaryTrie(trieDB(db), account.storageRoot, false)

# XXX: https://github.com/status-im/nimbus/issues/142#issuecomment-420583181
proc setStorageRoot*(db: var AccountStateDB, address: EthAddress, storageRoot: Hash256) =
  var account = db.getAccount(address)
  account.storageRoot = storageRoot
  db.setAccount(address, account)

proc getStorageRoot*(db: AccountStateDB, address: EthAddress): Hash256 =
  var account = db.getAccount(address)
  account.storageRoot

proc setStorage*(db: var AccountStateDB,
                 address: EthAddress,
                 slot: UInt256, value: UInt256) =
  var account = db.getAccount(address)
  var accountTrie = getAccountTrie(db, account)
  let slotAsKey = createTrieKeyFromSlot slot

  if value > 0:
    let encodedValue = rlp.encode(value).toRange
    accountTrie.put(slotAsKey, encodedValue)
  else:
    accountTrie.del(slotAsKey)

  # map slothash back to slot value
  # see iterator storage below
  var
    triedb = trieDB(db)
    # slotHash can be obtained from accountTrie.put?
    slotHash = keccakHash(slot.toByteArrayBE)
  triedb.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))

  account.storageRoot = accountTrie.rootHash
  db.setAccount(address, account)

iterator storage*(db: AccountStateDB, address: EthAddress): (UInt256, UInt256) =
  let
    storageRoot = db.getStorageRoot(address)
    triedb = trieDB(db)
  var trie = initHexaryTrie(triedb, storageRoot)

  for key, value in trie:
    if key.len != 0:
      var keyData = triedb.get(slotHashToSlotKey(key.toOpenArray).toOpenArray).toRange
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

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

proc setNonce*(db: AccountStateDB, address: EthAddress, newNonce: AccountNonce) =
  var account = db.getAccount(address)
  if newNonce != account.nonce:
    account.nonce = newNonce
    db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: EthAddress): AccountNonce =
  let account = db.getAccount(address)
  account.nonce

proc incNonce*(db: AccountStateDB, address: EthAddress) {.inline.} =
  db.setNonce(address, db.getNonce(address) + 1)

proc setCode*(db: AccountStateDB, address: EthAddress, code: ByteRange) =
  var account = db.getAccount(address)
  # TODO: implement JournalDB to store code and storage
  # also use JournalDB to revert state trie

  let
    newCodeHash = keccakHash(code.toOpenArray)
    triedb = trieDB(db)

  if code.len != 0:
    triedb.put(contractHashKey(newCodeHash).toOpenArray, code.toOpenArray)

  account.codeHash = newCodeHash
  db.setAccount(address, account)

proc getCode*(db: AccountStateDB, address: EthAddress): ByteRange =
  let triedb = trieDB(db)
  let data = triedb.get(contractHashKey(db.getCodeHash(address)).toOpenArray)
  data.toRange

proc hasCodeOrNonce*(db: AccountStateDB, address: EthAddress): bool {.inline.} =
  db.getNonce(address) != 0 or db.getCodeHash(address) != EMPTY_SHA3

proc dumpAccount*(db: AccountStateDB, addressS: string): string =
  let address = addressS.parseAddress
  return fmt"{addressS}: Storage: {db.getStorage(address, 0.u256)}; getAccount: {db.getAccount address}"

proc accountExists*(db: AccountStateDB, address: EthAddress): bool =
  db.trie.get(createRangeFromAddress address).len > 0

proc isEmptyAccount*(db: AccountStateDB, address: EthAddress): bool =
  let recordFound = db.trie.get(createRangeFromAddress address)
  assert(recordFound.len > 0)

  let account = rlp.decode(recordFound, Account)
  result = account.codeHash == EMPTY_SHA3 and
    account.balance.isZero and
    account.nonce == 0

proc isDeadAccount*(db: AccountStateDB, address: EthAddress): bool =
  let recordFound = db.trie.get(createRangeFromAddress address)
  if recordFound.len > 0:
    let account = rlp.decode(recordFound, Account)
    result = account.codeHash == EMPTY_SHA3 and
      account.balance.isZero and
      account.nonce == 0
  else:
    result = true

proc getCommittedStorage*(db: AccountStateDB, address: EthAddress, slot: UInt256): UInt256 =
  let tmpHash = db.rootHash
  db.rootHash = db.originalRoot
  var exists: bool
  shortTimeReadOnly(trieDB(db), db.transactionID):
    (result, exists) = db.getStorage(address, slot)
  db.rootHash = tmpHash

proc updateOriginalRoot*(db: AccountStateDB) =
  ## this proc will be called for every transaction
  db.originalRoot = db.rootHash
  # no need to rollback or dispose
  # transactionID, it will be handled elsewhere
  db.transactionID = trieDB(db).getTransactionID()

proc rootHash*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getAccount*(db: ReadOnlyStateDB, address: EthAddress): Account {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): ByteRange {.borrow.}
proc hasCodeOrNonce*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
