# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[sets, strformat],
  chronicles,
  eth/[common, rlp],
  ../constants,
  ../utils/utils,
  "."/[core_db, distinct_tries, storage_types]

logScope:
  topics = "state_db"

# aleth/geth/parity compatibility mode:
#
# affected test cases both in GST and BCT:
# - stSStoreTest\InitCollision.json
# - stRevertTest\RevertInCreateInInit.json
# - stCreate2\RevertInCreateInInitCreate2.json
#
# pyEVM sided with original Nimbus EVM
#
# implementation difference:
# Aleth/geth/parity using accounts cache.
# When contract creation happened on an existing
# but 'empty' account with non empty storage will
# get new empty storage root.
# Aleth cs. only clear the storage cache while both pyEVM
# and Nimbus will modify the state trie.
# During the next SSTORE call, aleth cs. calculate
# gas used based on this cached 'original storage value'.
# In other hand pyEVM and Nimbus will fetch
# 'original storage value' from state trie.
#
# Both Yellow Paper and EIP2200 are not clear about this
# situation but since aleth/geth/and parity implement this
# behaviour, we perhaps also need to implement it.
#
# TODO: should this compatibility mode enabled via
# compile time switch, runtime switch, or just hard coded
# it?
const
  aleth_compat = true

type
  AccountStateDB* = ref object
    trie: AccountsTrie
    originalRoot: KeccakHash   # will be updated for every transaction
    transactionID: CoreDbTxID
    when aleth_compat:
      cleared: HashSet[EthAddress]

  ReadOnlyStateDB* = distinct AccountStateDB

proc pruneTrie*(db: AccountStateDB): bool =
  db.trie.isPruning

func db*(db: AccountStateDB): CoreDbRef =
  db.trie.db

func kvt*(db: AccountStateDB): CoreDbKvtObj =
  db.trie.db.kvt

proc rootHash*(db: AccountStateDB): KeccakHash =
  db.trie.rootHash

proc `rootHash=`*(db: AccountStateDB, root: KeccakHash) =
  db.trie = initAccountsTrie(db.trie.db, root, db.trie.isPruning)

proc newAccountStateDB*(backingStore: CoreDbRef,
                        root: KeccakHash, pruneTrie: bool): AccountStateDB =
  result.new()
  result.trie = initAccountsTrie(backingStore, root, pruneTrie)
  result.originalRoot = root
  result.transactionID = backingStore.getTransactionID()
  when aleth_compat:
    result.cleared = initHashSet[EthAddress]()

proc getTrie*(db: AccountStateDB): CoreDbMptRef =
  db.trie.mpt

proc getSecureTrie*(db: AccountStateDB): CoreDbPhkRef =
  db.trie.phk

proc getAccount*(db: AccountStateDB, address: EthAddress): Account =
  let recordFound = db.trie.getAccountBytes(address)
  if recordFound.len > 0:
    result = rlp.decode(recordFound, Account)
  else:
    result = newAccount()

proc setAccount*(db: AccountStateDB, address: EthAddress, account: Account) =
  db.trie.putAccountBytes(address, rlp.encode(account))

proc deleteAccount*(db: AccountStateDB, address: EthAddress) =
  db.trie.delAccountBytes(address)

proc getCodeHash*(db: AccountStateDB, address: EthAddress): Hash256 =
  let account = db.getAccount(address)
  result = account.codeHash

proc getBalance*(db: AccountStateDB, address: EthAddress): UInt256 =
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: AccountStateDB, address: EthAddress, balance: UInt256) =
  var account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc addBalance*(db: AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)

proc subBalance*(db: AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) - delta)

template createTrieKeyFromSlot(slot: UInt256): auto =
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toBytesBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

template getStorageTrie(db: AccountStateDB, account: Account): auto =
  storageTrieForAccount(db.trie, account, false)

proc clearStorage*(db: AccountStateDB, address: EthAddress) =
  var account = db.getAccount(address)
  account.storageRoot = EMPTY_ROOT_HASH
  db.setAccount(address, account)
  when aleth_compat:
    db.cleared.incl address

proc getStorageRoot*(db: AccountStateDB, address: EthAddress): Hash256 =
  var account = db.getAccount(address)
  account.storageRoot

proc setStorage*(db: AccountStateDB,
                 address: EthAddress,
                 slot: UInt256, value: UInt256) =
  var account = db.getAccount(address)
  var accountTrie = getStorageTrie(db, account)
  let slotAsKey = createTrieKeyFromSlot slot

  if value > 0:
    let encodedValue = rlp.encode(value)
    accountTrie.putSlotBytes(slotAsKey, encodedValue)
  else:
    accountTrie.delSlotBytes(slotAsKey)

  # map slothash back to slot value
  # see iterator storage below
  var
    triedb = db.kvt
    # slotHash can be obtained from accountTrie.put?
    slotHash = keccakHash(slot.toBytesBE)
  triedb.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))

  account.storageRoot = accountTrie.rootHash
  db.setAccount(address, account)

iterator storage*(db: AccountStateDB, address: EthAddress): (UInt256, UInt256) =
  let
    storageRoot = db.getStorageRoot(address)
    triedb = db.kvt
    trie = db.db.mptPrune storageRoot

  for key, value in trie:
    if key.len != 0:
      var keyData = triedb.get(slotHashToSlotKey(key).toOpenArray)
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

proc getStorage*(db: AccountStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) =
  let
    account = db.getAccount(address)
    slotAsKey = createTrieKeyFromSlot slot
    storageTrie = getStorageTrie(db, account)

  let
    foundRecord = storageTrie.getSlotBytes(slotAsKey)

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

proc setCode*(db: AccountStateDB, address: EthAddress, code: openArray[byte]) =
  var account = db.getAccount(address)
  # TODO: implement JournalDB to store code and storage
  # also use JournalDB to revert state trie

  let
    newCodeHash = keccakHash(code)
    triedb = db.kvt

  if code.len != 0:
    triedb.put(contractHashKey(newCodeHash).toOpenArray, code)

  account.codeHash = newCodeHash
  db.setAccount(address, account)

proc getCode*(db: AccountStateDB, address: EthAddress): seq[byte] =
  let triedb = db.kvt
  triedb.get(contractHashKey(db.getCodeHash(address)).toOpenArray)

proc hasCodeOrNonce*(db: AccountStateDB, address: EthAddress): bool {.inline.} =
  db.getNonce(address) != 0 or db.getCodeHash(address) != EMPTY_SHA3

proc dumpAccount*(db: AccountStateDB, addressS: string): string =
  let address = addressS.parseAddress
  return fmt"{addressS}: Storage: {db.getStorage(address, 0.u256)}; getAccount: {db.getAccount address}"

proc accountExists*(db: AccountStateDB, address: EthAddress): bool =
  db.trie.getAccountBytes(address).len > 0

proc isEmptyAccount*(db: AccountStateDB, address: EthAddress): bool =
  let recordFound = db.trie.getAccountBytes(address)
  assert(recordFound.len > 0)

  let account = rlp.decode(recordFound, Account)
  result = account.codeHash == EMPTY_SHA3 and
    account.balance.isZero and
    account.nonce == 0

proc isDeadAccount*(db: AccountStateDB, address: EthAddress): bool =
  let recordFound = db.trie.getAccountBytes(address)
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
  db.transactionID.shortTimeReadOnly():
    when aleth_compat:
      if address in db.cleared:
        debug "Forced contract creation on existing account detected", address
        result = 0.u256
      else:
        result = db.getStorage(address, slot)[0]
    else:
      result = db.getStorage(address, slot)[0]
  db.rootHash = tmpHash

proc updateOriginalRoot*(db: AccountStateDB) =
  ## this proc will be called for every transaction
  db.originalRoot = db.rootHash
  # no need to rollback or dispose
  # transactionID, it will be handled elsewhere
  db.transactionID = db.db.getTransactionID()

  when aleth_compat:
    db.cleared.clear()

proc rootHash*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getAccount*(db: ReadOnlyStateDB, address: EthAddress): Account {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): seq[byte] {.borrow.}
proc hasCodeOrNonce*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
