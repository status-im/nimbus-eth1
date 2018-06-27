# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, tables,
  eth_common, nimcrypto, rlp, eth_trie/[hexary, memdb],
  ../constants, ../errors, ../validation, ../account, ../logging

type
  AccountStateDB* = ref object
    trie: HexaryTrie

proc rootHash*(accountDb: AccountStateDB): KeccakHash =
  accountDb.trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
# TODO: self.Trie.rootHash = value

proc newAccountStateDB*(backingStore: TrieDatabaseRef,
                        root: KeccakHash, readOnly: bool = false): AccountStateDB =
  result.trie = initHexaryTrie(backingStore, root)

proc logger*(db: AccountStateDB): Logger =
  logging.getLogger("db.State")

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

proc setAccount(db: AccountStateDB, address: EthAddress, account: Account) =
  db.trie.put createRangeFromAddress(address), rlp.encode(account)

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
  var account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: EthAddress, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)

proc stringToByteRange*(str: string): ByteRange =
  # TODO: There might be a more efficient way to
  # implement this without creating a copy.
  var res = newSeq[byte](str.len)
  copyMem(addr res[0], unsafeAddr str[0], str.len)
  return res.toRange

template createTrieKeyFromSlot(slot: UInt256): ByteRange =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  stringToByteRange("0x" & slot.dumpHex)
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))

proc setStorage*(db: var AccountStateDB,
                 address: EthAddress,
                 slot: UInt256, value: UInt256) =
  #validateGte(value, 0, title="Storage Value")
  #validateGte(slot, 0, title="Storage Slot")
  validateCanonicalAddress(address, title="Storage Address")

  var account = db.getAccount(address)
  var storage = initHexaryTrie(db.trie.db, account.storageRoot)
  let slotAsKey = createTrieKeyFromSlot slot

  if value > 0:
    let encodedValue = rlp.encode value
    storage.put(slotAsKey, encodedValue)
  else:
    storage.del(slotAsKey)

  account.storageRoot = storage.rootHash
  db.setAccount(address, account)

proc getStorage*(db: AccountStateDB, address: EthAddress, slot: UInt256): (UInt256, bool) =
  validateCanonicalAddress(address, title="Storage Address")
  #validateGte(slot, 0, title="Storage Slot")

  let
    account = db.getAccount(address)
    slotAsKey = createTrieKeyFromSlot slot
    storage = initHexaryTrie(db.trie.db, account.storageRoot)
    foundRecord = storage.get(slotAsKey)

  if foundRecord.len > 0:
    result = (rlp.decode(foundRecord, UInt256), true)
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

proc toByteRange_Unnecessary*(h: KeccakHash): ByteRange =
  ## XXX: Another proc used to mark unnecessary conversions it the code
  var s = @(h.data)
  return s.toRange

proc setCode*(db: var AccountStateDB, address: EthAddress, code: ByteRange) =
  validateCanonicalAddress(address, title="Storage Address")

  var account = db.getAccount(address)
  account.codeHash = keccak256.digest code.toOpenArray
  # XXX: this uses the journaldb in py-evm
  db.trie.put(account.codeHash.toByteRange_Unnecessary, code)
  db.setAccount(address, account)

proc getCode*(db: AccountStateDB, address: EthAddress): ByteRange =
  let codeHash = db.getCodeHash(address)
  result = db.trie.get(codeHash.toByteRange_Unnecessary)

