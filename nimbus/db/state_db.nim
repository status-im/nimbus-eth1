# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, strformat, tables,
  chronicles, eth_common, nimcrypto, rlp, eth_trie/[hexary, db],
  ../constants, ../errors, ../validation,
  storage_types

logScope:
  topics = "state_db"

type
  AccountStateDB* = ref object
    trie:         SecureHexaryTrie
    accountCodes: TableRef[Hash256, ByteRange]

proc rootHash*(accountDb: AccountStateDB): KeccakHash =
  accountDb.trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
# TODO: self.Trie.rootHash = value

proc newAccountStateDB*(backingStore: TrieDatabaseRef,
                        root: KeccakHash, pruneTrie: bool, readOnly: bool = false,
                        accountCodes = newTable[Hash256, ByteRange]()): AccountStateDB =
  result.new()
  result.trie = initSecureHexaryTrie(backingStore, root, pruneTrie)
  result.accountCodes = accountCodes

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

template getAccountTrie(stateDb: AccountStateDB, account: Account): auto =
  initSecureHexaryTrie(HexaryTrie(stateDb.trie).db, account.storageRoot)

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
    triedb = HexaryTrie(db.trie).db
    # slotHash can be obtained from accountTrie.put?
    slotHash = keccak256.digest(slot.toByteArrayBE)
  triedb.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))

  account.storageRoot = accountTrie.rootHash
  db.setAccount(address, account)

iterator storage*(db: AccountStateDB, address: EthAddress): (UInt256, UInt256) =
  let
    storageRoot = db.getStorageRoot(address)
    triedb = HexaryTrie(db.trie).db
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

proc setNonce*(db: var AccountStateDB, address: EthAddress, newNonce: AccountNonce) =
  var account = db.getAccount(address)
  if newNonce != account.nonce:
    account.nonce = newNonce
    db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: EthAddress): AccountNonce =
  let account = db.getAccount(address)
  account.nonce

proc setCode*(db: var AccountStateDB, address: EthAddress, code: ByteRange) =
  var account = db.getAccount(address)
  let newCodeHash = keccak256.digest code.toOpenArray
  if newCodeHash != account.codeHash:
    account.codeHash = newCodeHash
    db.accountCodes[newCodeHash] = code
    # XXX: this uses the journaldb in py-evm
    # db.trie.put(account.codeHash.toByteRange_Unnecessary, code)
    db.setAccount(address, account)

proc getCode*(db: AccountStateDB, address: EthAddress): ByteRange =
  db.accountCodes.getOrDefault(db.getCodeHash(address))

proc hasCodeOrNonce*(account: AccountStateDB, address: EthAddress): bool {.inline.} =
  account.getNonce(address) != 0 or account.getCodeHash(address) != EMPTY_SHA3

proc dumpAccount*(db: AccountStateDB, addressS: string): string =
  let address = addressS.parseAddress
  return fmt"{addressS}: Storage: {db.getStorage(address, 0.u256)}; getAccount: {db.getAccount address}"

